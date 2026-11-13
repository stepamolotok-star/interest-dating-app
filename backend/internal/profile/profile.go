// Package profile — профиль пользователя: поля и их видимость, интересы,
// цели и фильтры поиска.
package profile

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/catalog"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/matching"
)

// Видимость поля (ТЗ, раздел 4).
const (
	Anonymous    = "anonymous"     // видно в анонимной карточке
	AfterMatch   = "after_match"   // видно после взаимного «Интересно»
	MatchingOnly = "matching_only" // участвует в подборе, никому не показывается
	Hidden       = "hidden"
)

// DefaultVisibility — значения по умолчанию: самые закрытые из разумных.
var DefaultVisibility = map[string]string{
	"about":     Anonymous,
	"prompts":   Anonymous,
	"habits":    Anonymous,
	"diet":      Anonymous,
	"languages": Anonymous,
	"height":    MatchingOnly,
	"weight":    MatchingOnly,
	"body_type": MatchingOnly,
	"religion":  Hidden,
	// Фото видно в ленте сразу; можно открыть только после взаимного интереса.
	// В «Рядом» и в цели «Без обязательств» фото до взаимности скрыто всегда (пакеты feed, nearby).
	"photos": Anonymous,
}

// Допустимые привычки и их значения.
var HabitValues = map[string][]string{
	"smoking":    {"no", "sometimes", "yes"},
	"alcohol":    {"no", "sometimes", "yes"},
	"sport":      {"no", "sometimes", "regular"},
	"chronotype": {"lark", "owl"},
	"pets":       {"has", "wants", "no"},
	"has_kids":   {"yes", "no"},
	"wants_kids": {"yes", "no", "unsure"},
}

// Diets — допустимые типы питания.
var Diets = []string{"any", "vegetarian", "vegan", "pescatarian", "halal", "kosher", "healthy", "keto", "raw", "fasting"}

// BodyTypes — допустимое телосложение.
var BodyTypes = []string{"slim", "athletic", "average", "dense", "large"}

// Religions — допустимые значения религии (особая категория, ст. 10 152-ФЗ).
var Religions = []string{"orthodox", "christian", "islam", "buddhism", "judaism", "other", "none"}

// Ошибки.
var (
	ErrNotFound           = errors.New("профиль не найден")
	ErrNeedVerification   = errors.New("цель «Без обязательств» доступна после проверки фото и подтверждения, что вам есть 18 лет")
	ErrNeedSpecialConsent = errors.New("чтобы указать религию, нужно отдельное согласие на обработку таких данных")
)

// ValidationError — ошибка во входных данных.
type ValidationError struct{ Field, Message string }

func (e *ValidationError) Error() string { return e.Field + ": " + e.Message }

func invalid(field, msg string) error { return &ValidationError{field, msg} }

// Prompt — вопрос-подсказка с ответом («Идеальные выходные — это…»).
type Prompt struct {
	Question string `json:"question"`
	Answer   string `json:"answer"`
}

// Language — язык и уровень.
type Language struct {
	Code  string `json:"code"`
	Level string `json:"level"`
}

// Fields — редактируемые поля профиля.
type Fields struct {
	About               string            `json:"about"`
	Prompts             []Prompt          `json:"prompts"`
	HeightCm            *int              `json:"height_cm"`
	WeightKg            *int              `json:"weight_kg"`
	BodyType            string            `json:"body_type"`
	Habits              map[string]string `json:"habits"`
	Diet                string            `json:"diet"`
	Religion            string            `json:"religion"`
	ReligionForMatching bool              `json:"religion_for_matching"`
	ShowZodiac          bool              `json:"show_zodiac"`
	// AgeAsRange — в анкете возраст диапазоном («28–32») вместо точного числа.
	AgeAsRange bool       `json:"age_as_range"`
	Languages  []Language `json:"languages"`
}

// Validate проверяет поля.
func (f Fields) Validate() error {
	if utf8.RuneCountInString(f.About) > 500 {
		return invalid("about", "не длиннее 500 символов")
	}
	if len(f.Prompts) > 3 {
		return invalid("prompts", "не больше трёх подсказок")
	}
	for _, p := range f.Prompts {
		if strings.TrimSpace(p.Question) == "" || utf8.RuneCountInString(p.Question) > 100 {
			return invalid("prompts", "вопрос от 1 до 100 символов")
		}
		if strings.TrimSpace(p.Answer) == "" || utf8.RuneCountInString(p.Answer) > 150 {
			return invalid("prompts", "ответ от 1 до 150 символов")
		}
	}
	if f.HeightCm != nil && (*f.HeightCm < 120 || *f.HeightCm > 230) {
		return invalid("height_cm", "рост от 120 до 230 см")
	}
	if f.WeightKg != nil && (*f.WeightKg < 35 || *f.WeightKg > 250) {
		return invalid("weight_kg", "вес от 35 до 250 кг")
	}
	for k, v := range f.Habits {
		allowed, ok := HabitValues[k]
		if !ok || !slices.Contains(allowed, v) {
			return invalid("habits", fmt.Sprintf("недопустимое значение %s=%s", k, v))
		}
	}
	if f.BodyType != "" && !slices.Contains(BodyTypes, f.BodyType) {
		return invalid("body_type", "неизвестное телосложение")
	}
	if f.Religion != "" && !slices.Contains(Religions, f.Religion) {
		return invalid("religion", "неизвестное значение")
	}
	if f.Diet != "" && !slices.Contains(Diets, f.Diet) {
		return invalid("diet", "неизвестный тип питания")
	}
	if f.ReligionForMatching && f.Religion == "" {
		return invalid("religion_for_matching", "сначала укажите религию")
	}
	if len(f.Languages) > 10 {
		return invalid("languages", "не больше 10 языков")
	}
	return nil
}

// Service — работа с профилем.
type Service struct {
	DB      *pgxpool.Pool
	Catalog *catalog.Catalog
}

// SyncCatalog переносит каталог в таблицу interests (родители раньше детей).
func (s *Service) SyncCatalog(ctx context.Context) error {
	batch := &pgx.Batch{}
	for depth := 0; depth <= 2; depth++ {
		var walk func(nodes []catalog.Node)
		walk = func(nodes []catalog.Node) {
			for _, n := range nodes {
				if n.Depth == depth {
					var parent *string
					if n.Parent != "" {
						parent = &n.Parent
					}
					syn := n.Synonyms
					if syn == nil {
						syn = []string{}
					}
					batch.Queue(`INSERT INTO interests (id, parent_id, depth, name, synonyms) VALUES ($1, $2, $3, $4, $5)
						ON CONFLICT (id) DO UPDATE SET parent_id = $2, depth = $3, name = $4, synonyms = $5`,
						n.ID, parent, n.Depth, n.Name, syn)
				}
				walk(s.Catalog.Children(n.ID))
			}
		}
		walk(s.Catalog.Categories())
	}
	return s.DB.SendBatch(ctx, batch).Close()
}

// Get возвращает поля профиля.
func (s *Service) Get(ctx context.Context, userID string) (Fields, error) {
	var f Fields
	var prompts, habits, langs []byte
	var height, weight *int16
	var bodyType, diet, religion *string
	err := s.DB.QueryRow(ctx, `
		SELECT coalesce(about, ''), prompts, height_cm, weight_kg, body_type, habits, diet, religion,
		       religion_for_matching, show_zodiac, languages, age_as_range
		FROM profiles WHERE user_id = $1`, userID).Scan(&f.About, &prompts, &height, &weight, &bodyType,
		&habits, &diet, &religion, &f.ReligionForMatching, &f.ShowZodiac, &langs, &f.AgeAsRange)
	if errors.Is(err, pgx.ErrNoRows) {
		return Fields{}, ErrNotFound
	}
	if err != nil {
		return Fields{}, err
	}
	_ = json.Unmarshal(prompts, &f.Prompts)
	_ = json.Unmarshal(habits, &f.Habits)
	_ = json.Unmarshal(langs, &f.Languages)
	if height != nil {
		h := int(*height)
		f.HeightCm = &h
	}
	if weight != nil {
		w := int(*weight)
		f.WeightKg = &w
	}
	f.BodyType, f.Diet, f.Religion = deref(bodyType), deref(diet), deref(religion)
	return f, nil
}

// Update заменяет поля профиля. grantSpecial — пользователь только что дал
// отдельное согласие на обработку религиозных убеждений (ст. 10 152-ФЗ).
func (s *Service) Update(ctx context.Context, userID string, f Fields, grantSpecial bool, docVersion string) error {
	if err := f.Validate(); err != nil {
		return err
	}
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	if f.Religion == "" {
		// Религию убрали — согласие на её обработку больше не нужно, отзываем.
		if _, err := tx.Exec(ctx, `UPDATE consents SET revoked_at = now()
			WHERE user_id = $1 AND kind = 'special_category' AND revoked_at IS NULL`, userID); err != nil {
			return err
		}
	} else {
		if grantSpecial {
			if _, err := tx.Exec(ctx, `INSERT INTO consents (user_id, kind, doc_version) VALUES ($1, 'special_category', $2)`, userID, docVersion); err != nil {
				return err
			}
		} else {
			var ok bool
			if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM consents
				WHERE user_id = $1 AND kind = 'special_category' AND revoked_at IS NULL)`, userID).Scan(&ok); err != nil {
				return err
			}
			if !ok {
				return ErrNeedSpecialConsent
			}
		}
	}
	prompts, _ := json.Marshal(nonNil(f.Prompts))
	habits, _ := json.Marshal(nonNilMap(f.Habits))
	langs, _ := json.Marshal(nonNil(f.Languages))
	tag, err := tx.Exec(ctx, `
		UPDATE profiles SET about = $2, prompts = $3, height_cm = $4, weight_kg = $5, body_type = $6,
			habits = $7, diet = $8, religion = $9, religion_for_matching = $10, show_zodiac = $11,
			languages = $12, age_as_range = $13, updated_at = now()
		WHERE user_id = $1`, userID, f.About, prompts, f.HeightCm, f.WeightKg, nullable(f.BodyType),
		habits, nullable(f.Diet), nullable(f.Religion), f.ReligionForMatching, f.ShowZodiac, langs, f.AgeAsRange)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return tx.Commit(ctx)
}

// Visibility возвращает видимость всех настраиваемых полей.
func (s *Service) Visibility(ctx context.Context, userID string) (map[string]string, error) {
	out := make(map[string]string, len(DefaultVisibility))
	for k, v := range DefaultVisibility {
		out[k] = v
	}
	rows, err := s.DB.Query(ctx, `SELECT field, visibility FROM profile_field_visibility WHERE user_id = $1`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var f, v string
		if err := rows.Scan(&f, &v); err != nil {
			return nil, err
		}
		out[f] = v
	}
	return out, rows.Err()
}

// SetVisibility меняет видимость полей.
func (s *Service) SetVisibility(ctx context.Context, userID string, changes map[string]string) error {
	batch := &pgx.Batch{}
	for field, vis := range changes {
		if _, ok := DefaultVisibility[field]; !ok {
			return invalid(field, "у этого поля нельзя менять видимость")
		}
		if !slices.Contains([]string{Anonymous, AfterMatch, MatchingOnly, Hidden}, vis) {
			return invalid(field, "неизвестная видимость")
		}
		if field == "photos" && vis != Anonymous && vis != AfterMatch {
			return invalid(field, "фото можно показывать всем или только после взаимного интереса")
		}
		batch.Queue(`INSERT INTO profile_field_visibility (user_id, field, visibility) VALUES ($1, $2, $3)
			ON CONFLICT (user_id, field) DO UPDATE SET visibility = $3`, userID, field, vis)
	}
	return s.DB.SendBatch(ctx, batch).Close()
}

// Interest — увлечение в профиле.
type Interest struct {
	ID             string         `json:"id"`
	Name           string         `json:"name,omitempty"`
	Level          matching.Level `json:"level"`
	SeekingPartner bool           `json:"seeking_partner"`
	Kind           string         `json:"kind,omitempty"` // catalog.KindFan — без степени увлечённости
}

// SetInterests заменяет список увлечений. Только конкретные увлечения
// (третий уровень каталога), от 1 до 50.
func (s *Service) SetInterests(ctx context.Context, userID string, items []Interest) error {
	if len(items) == 0 || len(items) > 50 {
		return invalid("items", "от 1 до 50 увлечений")
	}
	seen := map[string]bool{}
	for i, it := range items {
		n, ok := s.Catalog.Get(it.ID)
		if !ok || n.Depth != 2 {
			return invalid("items", "неизвестное увлечение "+it.ID)
		}
		if seen[it.ID] {
			return invalid("items", "повтор "+it.ID)
		}
		seen[it.ID] = true
		if n.IsFan() {
			// «Слушаю рок» — без степени увлечённости, храним нейтральный уровень.
			items[i].Level = matching.Curious
		} else if !matching.ValidLevel(it.Level) {
			return invalid("items", "неизвестный уровень у "+it.ID)
		}
	}
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	var old []string
	rows, err := tx.Query(ctx, `DELETE FROM user_interests WHERE user_id = $1 RETURNING interest_id`, userID)
	if err != nil {
		return err
	}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return err
		}
		old = append(old, id)
	}
	rows.Close()
	touched := old
	for _, it := range items {
		if _, err := tx.Exec(ctx, `INSERT INTO user_interests (user_id, interest_id, level, seeking_partner)
			VALUES ($1, $2, $3, $4)`, userID, it.ID, it.Level, it.SeekingPartner); err != nil {
			return err
		}
		touched = append(touched, it.ID)
	}
	// Счётчик популярности — для веса редкости в подборе.
	if _, err := tx.Exec(ctx, `UPDATE interests i SET usage_count =
		(SELECT count(*) FROM user_interests ui WHERE ui.interest_id = i.id) WHERE i.id = ANY($1)`, touched); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// Interests — увлечения пользователя.
func (s *Service) Interests(ctx context.Context, userID string) ([]Interest, error) {
	rows, err := s.DB.Query(ctx, `SELECT interest_id, level, seeking_partner FROM user_interests
		WHERE user_id = $1 ORDER BY interest_id`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Interest{}
	for rows.Next() {
		var it Interest
		if err := rows.Scan(&it.ID, &it.Level, &it.SeekingPartner); err != nil {
			return nil, err
		}
		if n, ok := s.Catalog.Get(it.ID); ok {
			it.Name, it.Kind = n.Name, n.Kind
		}
		out = append(out, it)
	}
	return out, rows.Err()
}

// GoalSetting — цель и её состояние.
type GoalSetting struct {
	Goal          matching.Goal `json:"goal"`
	Active        bool          `json:"active"`
	NearbyVisible bool          `json:"nearby_visible"`
}

// SetGoals заменяет набор целей. «Без обязательств» — только с проверенным
// фото и возрастом через Госуслуги.
func (s *Service) SetGoals(ctx context.Context, userID string, goals []GoalSetting) error {
	needVerified := false
	for _, g := range goals {
		if !g.Goal.Valid() {
			return invalid("goals", "неизвестная цель "+string(g.Goal))
		}
		if g.Goal == matching.Casual && g.Active {
			needVerified = true
		}
	}
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if needVerified {
		var ok bool
		if err := tx.QueryRow(ctx, `SELECT photo_verified_at IS NOT NULL AND gosuslugi_verified_at IS NOT NULL
			FROM users WHERE id = $1`, userID).Scan(&ok); err != nil {
			return err
		}
		if !ok {
			return ErrNeedVerification
		}
	}
	if _, err := tx.Exec(ctx, `DELETE FROM user_goals WHERE user_id = $1`, userID); err != nil {
		return err
	}
	for _, g := range goals {
		if _, err := tx.Exec(ctx, `INSERT INTO user_goals (user_id, goal, active, nearby_visible) VALUES ($1, $2, $3, $4)`,
			userID, g.Goal, g.Active, g.NearbyVisible); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

// Goals — цели пользователя.
func (s *Service) Goals(ctx context.Context, userID string) ([]GoalSetting, error) {
	rows, err := s.DB.Query(ctx, `SELECT goal, active, nearby_visible FROM user_goals WHERE user_id = $1 ORDER BY goal`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []GoalSetting{}
	for rows.Next() {
		var g GoalSetting
		if err := rows.Scan(&g.Goal, &g.Active, &g.NearbyVisible); err != nil {
			return nil, err
		}
		out = append(out, g)
	}
	return out, rows.Err()
}

// SetPrefs сохраняет фильтры для цели.
func (s *Service) SetPrefs(ctx context.Context, userID string, goal matching.Goal, p matching.Prefs) error {
	if !goal.Valid() {
		return invalid("goal", "неизвестная цель")
	}
	if err := p.Validate(goal); err != nil {
		return invalid("prefs", err.Error())
	}
	for _, id := range p.Interests {
		if _, ok := s.Catalog.Get(id); !ok {
			return invalid("prefs", "неизвестный интерес "+id)
		}
	}
	raw, _ := json.Marshal(p)
	_, err := s.DB.Exec(ctx, `INSERT INTO goal_prefs (user_id, goal, prefs) VALUES ($1, $2, $3)
		ON CONFLICT (user_id, goal) DO UPDATE SET prefs = $3, updated_at = now()`, userID, goal, raw)
	return err
}

// Prefs возвращает фильтры для цели (пустые, если не заданы).
func (s *Service) Prefs(ctx context.Context, userID string, goal matching.Goal) (matching.Prefs, error) {
	var raw []byte
	err := s.DB.QueryRow(ctx, `SELECT prefs FROM goal_prefs WHERE user_id = $1 AND goal = $2`, userID, goal).Scan(&raw)
	if errors.Is(err, pgx.ErrNoRows) {
		return matching.Prefs{}, nil
	}
	if err != nil {
		return matching.Prefs{}, err
	}
	var p matching.Prefs
	return p, json.Unmarshal(raw, &p)
}

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

func nullable(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func nonNil[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}

func nonNilMap(m map[string]string) map[string]string {
	if m == nil {
		return map[string]string{}
	}
	return m
}
