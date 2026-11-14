// Package feed — анкетная лента и взаимное «Интересно».
//
// Лента отдаёт только анонимные карточки (уровень 0): возрастной диапазон,
// цель, общие интересы и поля, которые человек сам открыл как «анонимные».
// Имя и фото появляются только после совпадения.
package feed

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/catalog"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/limits"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/matching"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/profile"
)

// Настройки ленты.
const (
	CandidatePool  = 500                 // сколько кандидатов оцениваем за раз
	InterestTTL    = 30 * 24 * time.Hour // сколько живёт одностороннее «Интересно» в ленте
	SkipCooldown   = 30 * 24 * time.Hour // через сколько пропущенный человек может вернуться
	DefaultLimit   = 20
	defaultRespond = 0.5 // доля ответов, пока статистики нет
)

// Ошибки.
var (
	ErrGoalNotActive = errors.New("эта цель у вас не включена")
	ErrNotAvailable  = errors.New("этот человек сейчас недоступен")
)

// Service — лента.
type Service struct {
	DB      *pgxpool.Pool
	Catalog *catalog.Catalog
	Now     func() time.Time
}

func (s *Service) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// Card — анонимная карточка кандидата.
type Card struct {
	UserID string `json:"user_id"`
	Name   string `json:"name"`
	// PhotosHidden — фото до взаимного интереса размыто: так решил сам человек,
	// это цель «Без обязательств» или карточка из «Рядом».
	PhotosHidden bool   `json:"photos_hidden"`
	AgeRange     string `json:"age_range"`
	// Age — точный возраст; 0 (нет в JSON), если человек показывает возраст диапазоном.
	Age           int                       `json:"age,omitempty"`
	Goal          matching.Goal             `json:"goal"`
	PhotoVerified bool                      `json:"photo_verified"`
	AgeVerified   bool                      `json:"age_verified"`
	Score         int                       `json:"score"`
	Explanation   string                    `json:"explanation"`
	Shared        []matching.SharedInterest `json:"shared_interests"`
	OtherInterest int                       `json:"other_interests_count"`
	// Остальные интересы человека (названия): интересы — суть приложения, их видно сразу.
	Others    []string           `json:"other_interests"`
	About     string             `json:"about,omitempty"`
	Prompts   []profile.Prompt   `json:"prompts,omitempty"`
	Habits    map[string]string  `json:"habits,omitempty"`
	Diet      string             `json:"diet,omitempty"`
	Languages []profile.Language `json:"languages,omitempty"`
	Zodiac    string             `json:"zodiac,omitempty"`
	Distance  string             `json:"distance,omitempty"` // только в «Рядом»: «до 1 км»
}

// candidate — всё, что загружено о человеке.
type candidate struct {
	mp         matching.Profile
	city       string // код города или (старые профили) название в нижнем регистре
	about      string
	prompts    []profile.Prompt
	languages  []profile.Language
	showZodiac bool
	name       string
	ageAsRange bool
	zodiac     string
	vis        map[string]string
}

func (c *candidate) visible(field string) bool { return c.vis[field] == profile.Anonymous }

// Feed — лента для цели, лучшие сверху.
func (s *Service) Feed(ctx context.Context, viewerID string, goal matching.Goal, limit int) ([]Card, error) {
	if limit <= 0 || limit > 50 {
		limit = DefaultLimit
	}
	return s.rank(ctx, viewerID, goal, limit, nil, nil)
}

// Rank — то же, что лента, но среди заданных людей (например, тех, кто
// рядом). prefs, если задан, заменяет фильтры смотрящего (шаблон поиска).
func (s *Service) Rank(ctx context.Context, viewerID string, goal matching.Goal, ids []string, prefs *matching.Prefs) ([]Card, error) {
	if len(ids) == 0 {
		return []Card{}, nil
	}
	return s.rank(ctx, viewerID, goal, len(ids), ids, prefs)
}

func (s *Service) rank(ctx context.Context, viewerID string, goal matching.Goal, limit int, only []string, prefs *matching.Prefs) ([]Card, error) {
	now := s.now()
	viewers, err := s.load(ctx, []string{viewerID}, now)
	if err != nil {
		return nil, err
	}
	v, ok := viewers[viewerID]
	if !ok {
		return nil, ErrNotAvailable
	}
	if !hasGoal(v.mp, goal) {
		return nil, ErrGoalNotActive
	}
	if prefs != nil {
		v.mp.Prefs[goal] = *prefs
	}

	// $3 — город (для ленты) или NULL; $7 — список людей (для «Рядом») или NULL.
	var city *string
	var idsFilter []string
	if only == nil {
		city = &v.city
	} else {
		idsFilter = only
	}
	rows, err := s.DB.Query(ctx, `
		SELECT u.id FROM users u
		JOIN profiles p ON p.user_id = u.id
		JOIN user_goals g ON g.user_id = u.id AND g.goal = $2 AND g.active
		LEFT JOIN visibility_settings vs ON vs.user_id = u.id
		WHERE u.id <> $1 AND u.deleted_at IS NULL AND `+VisibleUserSQL+`
		  AND ($3::text IS NULL OR coalesce(p.city_id, lower(p.city)) = $3)
		  AND ($7::uuid[] IS NULL OR u.id = ANY($7::uuid[]))
		  AND NOT EXISTS (SELECT 1 FROM blocks b WHERE (b.blocker = $1 AND b.blocked = u.id) OR (b.blocker = u.id AND b.blocked = $1))
		  AND NOT EXISTS (SELECT 1 FROM interests_expressed e WHERE e.from_user = $1 AND e.to_user = u.id AND e.goal = $2 AND e.expires_at > $4)
		  AND NOT EXISTS (SELECT 1 FROM skips sk WHERE sk.viewer = $1 AND sk.target = u.id AND sk.goal = $2 AND sk.created_at > $5)
		  AND NOT EXISTS (SELECT 1 FROM matches m WHERE m.ended_at IS NULL AND m.goal = $2
		                  AND ((m.user_a = $1 AND m.user_b = u.id) OR (m.user_a = u.id AND m.user_b = $1)))
		  AND NOT (coalesce(vs.hide_from_contacts, false) AND EXISTS (
		      SELECT 1 FROM contact_hashes ch, users me
		      WHERE me.id = $1 AND ch.user_id = u.id AND ch.phone_hash = me.phone_key))
		ORDER BY u.last_active_at DESC
		LIMIT $6`, viewerID, goal, city, now, now.Add(-SkipCooldown), CandidatePool, idsFilter)
	if err != nil {
		return nil, err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return nil, err
	}
	cands, err := s.load(ctx, ids, now)
	if err != nil {
		return nil, err
	}
	scorer, err := s.scorer(ctx, v, cands, now)
	if err != nil {
		return nil, err
	}

	cards := make([]Card, 0, limit)
	for _, id := range ids {
		c, ok := cands[id]
		if !ok {
			continue
		}
		if ok, _ := matching.Eligible(v.mp, c.mp, goal); !ok {
			continue
		}
		card := s.card(c, goal, scorer.Score(v.mp, c.mp, goal))
		// Кто прячет свои фото до взаимности, тот и чужие видит только после неё — честно в обе стороны.
		if !v.visible("photos") {
			card.PhotosHidden = true
		}
		cards = append(cards, card)
	}
	sort.SliceStable(cards, func(i, j int) bool { return cards[i].Score > cards[j].Score })
	if len(cards) > limit {
		cards = cards[:limit]
	}
	return cards, nil
}

func (s *Service) card(c *candidate, goal matching.Goal, r matching.Result) Card {
	card := Card{
		UserID: c.mp.ID, Name: c.name, AgeRange: AgeRange(c.mp.Age), Goal: goal,
		PhotosHidden:  !c.visible("photos") || goal == matching.Casual,
		PhotoVerified: c.mp.PhotoVerified, AgeVerified: c.mp.AgeVerified,
		Score: r.Score, Explanation: r.Explanation, Shared: r.Shared,
	}
	if card.Shared == nil {
		card.Shared = []matching.SharedInterest{}
	}
	shared := make(map[string]bool, len(card.Shared))
	for _, x := range card.Shared {
		shared[x.ID] = true
	}
	card.Others = []string{}
	for _, i := range c.mp.Interests {
		if !shared[i.ID] {
			card.Others = append(card.Others, s.Catalog.Name(i.ID))
		}
	}
	card.OtherInterest = len(card.Others)
	if !c.ageAsRange {
		card.Age = c.mp.Age
	}
	if c.visible("about") {
		card.About = c.about
	}
	if c.visible("prompts") {
		card.Prompts = c.prompts
	}
	if c.visible("habits") {
		card.Habits = c.mp.Habits
	}
	if c.visible("diet") {
		card.Diet = c.mp.Diet
	}
	if c.visible("languages") {
		card.Languages = c.languages
	}
	if c.showZodiac {
		card.Zodiac = c.zodiac
	}
	return card
}

// AgeRange — возраст пятилетним диапазоном: 30 → «28–32». Точный возраст
// в анонимной карточке не показываем.
func AgeRange(age int) string {
	if age < 18 {
		age = 18
	}
	lo := 18 + (age-18)/5*5
	return fmt.Sprintf("%d–%d", lo, lo+4)
}

// InterestResult — итог нажатия «Интересно».
type InterestResult struct {
	Matched bool   `json:"matched"`
	MatchID string `json:"match_id,omitempty"`
}

// VisibleUserSQL — условие «человека можно показывать другим»: не заблокирован,
// не отстранён и не скрыт до решения модератора. Алиас таблицы users — u.
const VisibleUserSQL = `u.banned_at IS NULL AND (u.suspended_until IS NULL OR u.suspended_until <= now()) AND NOT u.on_hold`

// Interest — «Интересно». Если вторая сторона уже нажала «Интересно»,
// создаётся совпадение. Иначе вторая сторона ничего не узнает.
func (s *Service) Interest(ctx context.Context, viewerID, targetID string, goal matching.Goal, interestID string) (InterestResult, error) {
	if !validUUID(targetID) {
		return InterestResult{}, ErrNotAvailable
	}
	now := s.now()
	people, err := s.load(ctx, []string{viewerID, targetID}, now)
	if err != nil {
		return InterestResult{}, err
	}
	v, t := people[viewerID], people[targetID]
	if v == nil || t == nil {
		return InterestResult{}, ErrNotAvailable
	}
	if !hasGoal(v.mp, goal) {
		return InterestResult{}, ErrGoalNotActive
	}
	var visible bool
	if err := s.DB.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM users u WHERE u.id = $1 AND `+VisibleUserSQL+`)`,
		targetID).Scan(&visible); err != nil {
		return InterestResult{}, err
	}
	if !visible {
		return InterestResult{}, ErrNotAvailable
	}
	var likes int
	if err := s.DB.QueryRow(ctx, `SELECT count(*) FROM interests_expressed WHERE from_user = $1 AND created_at > $2`,
		viewerID, now.Add(-24*time.Hour)).Scan(&likes); err != nil {
		return InterestResult{}, err
	}
	if likes >= limits.LikesPerDay {
		return InterestResult{}, limits.ErrLikes
	}
	if ok, _ := matching.Eligible(v.mp, t.mp, goal); !ok {
		return InterestResult{}, ErrNotAvailable
	}
	var marked *string
	if interestID != "" {
		if !hasInterest(v.mp, interestID) || !hasInterest(t.mp, interestID) {
			return InterestResult{}, &profile.ValidationError{Field: "interest_id", Message: "отметить можно только общий интерес"}
		}
		marked = &interestID
	}

	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return InterestResult{}, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	a, b := order(viewerID, targetID)
	// Блокировка пары: два одновременных «Интересно» не потеряют совпадение.
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext($1))`, a+b+string(goal)); err != nil {
		return InterestResult{}, err
	}
	var blocked bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM blocks WHERE (blocker = $1 AND blocked = $2) OR (blocker = $2 AND blocked = $1))`,
		viewerID, targetID).Scan(&blocked); err != nil {
		return InterestResult{}, err
	}
	if blocked {
		return InterestResult{}, ErrNotAvailable
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO interests_expressed (from_user, to_user, goal, interest_id, created_at, expires_at)
		VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (from_user, to_user, goal) DO UPDATE SET interest_id = $4, created_at = $5, expires_at = $6`,
		viewerID, targetID, goal, marked, now, now.Add(InterestTTL)); err != nil {
		return InterestResult{}, err
	}
	var mutual bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM interests_expressed
		WHERE from_user = $1 AND to_user = $2 AND goal = $3 AND expires_at > $4)`,
		targetID, viewerID, goal, now).Scan(&mutual); err != nil {
		return InterestResult{}, err
	}
	if !mutual {
		return InterestResult{}, tx.Commit(ctx)
	}

	var matchID string
	err = tx.QueryRow(ctx, `
		INSERT INTO matches (user_a, user_b, goal, created_at) VALUES ($1, $2, $3, $4)
		ON CONFLICT (user_a, user_b, goal) WHERE ended_at IS NULL DO NOTHING
		RETURNING id`, a, b, goal, now).Scan(&matchID)
	if errors.Is(err, pgx.ErrNoRows) {
		err = tx.QueryRow(ctx, `SELECT id FROM matches WHERE user_a = $1 AND user_b = $2 AND goal = $3 AND ended_at IS NULL`,
			a, b, goal).Scan(&matchID)
	}
	if err != nil {
		return InterestResult{}, err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM interests_expressed
		WHERE goal = $3 AND ((from_user = $1 AND to_user = $2) OR (from_user = $2 AND to_user = $1))`,
		viewerID, targetID, goal); err != nil {
		return InterestResult{}, err
	}
	return InterestResult{Matched: true, MatchID: matchID}, tx.Commit(ctx)
}

// Skip — «Пропустить»: человек не появится в ленте 30 дней.
func (s *Service) Skip(ctx context.Context, viewerID, targetID string, goal matching.Goal) error {
	if viewerID == targetID || !goal.Valid() || !validUUID(targetID) {
		return ErrNotAvailable
	}
	_, err := s.DB.Exec(ctx, `INSERT INTO skips (viewer, target, goal, created_at) VALUES ($1, $2, $3, $4)
		ON CONFLICT (viewer, target, goal) DO UPDATE SET created_at = $4`, viewerID, targetID, goal, s.now())
	return err
}

// scorer готовит оценщик с популярностью интересов из базы.
func (s *Service) scorer(ctx context.Context, v *candidate, cands map[string]*candidate, now time.Time) (matching.Scorer, error) {
	ids := map[string]bool{}
	for _, ui := range v.mp.Interests {
		ids[ui.ID] = true
	}
	for _, c := range cands {
		for _, ui := range c.mp.Interests {
			ids[ui.ID] = true
		}
	}
	list := make([]string, 0, len(ids))
	for id := range ids {
		list = append(list, id)
	}
	pop := map[string]int{}
	rows, err := s.DB.Query(ctx, `SELECT id, usage_count FROM interests WHERE id = ANY($1)`, list)
	if err != nil {
		return matching.Scorer{}, err
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		var n int
		if err := rows.Scan(&id, &n); err != nil {
			return matching.Scorer{}, err
		}
		pop[id] = n
	}
	return matching.Scorer{
		Catalog:    s.Catalog,
		Popularity: func(id string) int { return pop[id] },
		Now:        func() time.Time { return now },
	}, rows.Err()
}

// load загружает профили пачкой.
func (s *Service) load(ctx context.Context, ids []string, now time.Time) (map[string]*candidate, error) {
	out := make(map[string]*candidate, len(ids))
	if len(ids) == 0 {
		return out, nil
	}
	rows, err := s.DB.Query(ctx, `
		SELECT u.id, u.birth_date, u.gender, u.photo_verified_at IS NOT NULL, u.gosuslugi_verified_at IS NOT NULL,
		       u.last_active_at, coalesce(p.city_id, lower(p.city)), coalesce(p.about, ''), p.prompts, coalesce(p.height_cm, 0), coalesce(p.weight_kg, 0),
		       p.habits, coalesce(p.diet, ''), coalesce(p.religion, ''), p.religion_for_matching, p.show_zodiac, p.languages, p.age_as_range, p.display_name
		FROM users u JOIN profiles p ON p.user_id = u.id
		WHERE u.id = ANY($1::uuid[]) AND u.deleted_at IS NULL`, ids)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		c := &candidate{vis: map[string]string{}}
		var birth time.Time
		var prompts, habits, langs []byte
		var height, weight int16
		err := rows.Scan(&c.mp.ID, &birth, &c.mp.Gender, &c.mp.PhotoVerified, &c.mp.AgeVerified, &c.mp.LastActive,
			&c.city, &c.about, &prompts, &height, &weight, &habits, &c.mp.Diet, &c.mp.Religion,
			&c.mp.ReligionForMatching, &c.showZodiac, &langs, &c.ageAsRange, &c.name)
		if err != nil {
			rows.Close()
			return nil, err
		}
		_ = json.Unmarshal(prompts, &c.prompts)
		_ = json.Unmarshal(habits, &c.mp.Habits)
		_ = json.Unmarshal(langs, &c.languages)
		c.mp.Age = age(birth, now)
		c.mp.HeightCm, c.mp.WeightKg = int(height), int(weight)
		c.zodiac = Zodiac(birth)
		if c.showZodiac {
			c.mp.Zodiac = c.zodiac // в подборе — только если человек сам открыл знак
		}
		c.mp.ResponseRate = defaultRespond
		c.mp.Prefs = map[matching.Goal]matching.Prefs{}
		for f, vis := range profile.DefaultVisibility {
			c.vis[f] = vis
		}
		out[c.mp.ID] = c
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	type q struct {
		sql  string
		scan func(pgx.Rows) error
	}
	queries := []q{
		{`SELECT user_id, goal FROM user_goals WHERE active AND user_id = ANY($1::uuid[])`, func(r pgx.Rows) error {
			var id string
			var g matching.Goal
			if err := r.Scan(&id, &g); err != nil {
				return err
			}
			if c := out[id]; c != nil {
				c.mp.Goals = append(c.mp.Goals, g)
			}
			return nil
		}},
		{`SELECT user_id, interest_id, level, seeking_partner FROM user_interests WHERE user_id = ANY($1::uuid[]) ORDER BY interest_id`, func(r pgx.Rows) error {
			var id string
			var ui matching.UserInterest
			if err := r.Scan(&id, &ui.ID, &ui.Level, &ui.SeekingPartner); err != nil {
				return err
			}
			if c := out[id]; c != nil {
				c.mp.Interests = append(c.mp.Interests, ui)
			}
			return nil
		}},
		{`SELECT user_id, goal, prefs FROM goal_prefs WHERE user_id = ANY($1::uuid[])`, func(r pgx.Rows) error {
			var id string
			var g matching.Goal
			var raw []byte
			if err := r.Scan(&id, &g, &raw); err != nil {
				return err
			}
			var p matching.Prefs
			if err := json.Unmarshal(raw, &p); err != nil {
				return err
			}
			if c := out[id]; c != nil {
				c.mp.Prefs[g] = p
			}
			return nil
		}},
		{`SELECT user_id, field, visibility FROM profile_field_visibility WHERE user_id = ANY($1::uuid[])`, func(r pgx.Rows) error {
			var id, f, vis string
			if err := r.Scan(&id, &f, &vis); err != nil {
				return err
			}
			if c := out[id]; c != nil {
				c.vis[f] = vis
			}
			return nil
		}},
	}
	for _, qq := range queries {
		rows, err := s.DB.Query(ctx, qq.sql, ids)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			if err := qq.scan(rows); err != nil {
				rows.Close()
				return nil, err
			}
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return nil, err
		}
	}
	// Поля со «скрыто» не участвуют и в подборе.
	for _, c := range out {
		if c.vis["height"] == profile.Hidden {
			c.mp.HeightCm = 0
		}
		if c.vis["weight"] == profile.Hidden {
			c.mp.WeightKg = 0
		}
		if c.vis["diet"] == profile.Hidden {
			c.mp.Diet = ""
		}
		if c.vis["habits"] == profile.Hidden {
			c.mp.Habits = nil
		}
	}
	return out, nil
}

// Zodiac — знак зодиака по дате рождения (идентификатор для API).
func Zodiac(b time.Time) string {
	md := int(b.Month())*100 + b.Day()
	switch {
	case md >= 321 && md <= 419:
		return "aries"
	case md >= 420 && md <= 520:
		return "taurus"
	case md >= 521 && md <= 620:
		return "gemini"
	case md >= 621 && md <= 722:
		return "cancer"
	case md >= 723 && md <= 822:
		return "leo"
	case md >= 823 && md <= 922:
		return "virgo"
	case md >= 923 && md <= 1022:
		return "libra"
	case md >= 1023 && md <= 1121:
		return "scorpio"
	case md >= 1122 && md <= 1221:
		return "sagittarius"
	case md >= 1222 || md <= 119:
		return "capricorn"
	case md >= 120 && md <= 218:
		return "aquarius"
	default:
		return "pisces"
	}
}

func age(birth, now time.Time) int {
	y := now.Year() - birth.Year()
	if now.Month() < birth.Month() || (now.Month() == birth.Month() && now.Day() < birth.Day()) {
		y--
	}
	return y
}

func hasGoal(p matching.Profile, g matching.Goal) bool {
	for _, x := range p.Goals {
		if x == g {
			return true
		}
	}
	return false
}

func hasInterest(p matching.Profile, id string) bool {
	for _, ui := range p.Interests {
		if ui.ID == id {
			return true
		}
	}
	return false
}

func order(a, b string) (string, string) {
	if a < b {
		return a, b
	}
	return b, a
}

var uuidPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

func validUUID(s string) bool { return uuidPattern.MatchString(s) }
