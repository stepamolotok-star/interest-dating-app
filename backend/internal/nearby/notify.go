package nearby

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/feed"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/matching"
)

// Правила уведомлений (ТЗ, раздел 6).
const (
	RepeatAfter      = 7 * 24 * time.Hour // об одном человеке — не чаще раза в 7 дней
	MaxTemplates     = 10
	DefaultMinScore  = 60
	DefaultDailyCap  = 5
	maxDailyCapLimit = 20
)

// Template — шаблон поиска («Напарник на мотопробег»).
type Template struct {
	ID           string         `json:"id"`
	Goal         matching.Goal  `json:"goal"`
	Name         string         `json:"name"`
	Prefs        matching.Prefs `json:"prefs"`
	NotifyNearby bool           `json:"notify_nearby"`
	MinScore     int            `json:"min_score"`
	DailyLimit   int            `json:"daily_limit"`
	QuietFrom    string         `json:"quiet_from,omitempty"` // «23:00»
	QuietTo      string         `json:"quiet_to,omitempty"`   // «08:00»
}

// CreateTemplate сохраняет шаблон.
func (s *Service) CreateTemplate(ctx context.Context, userID string, t Template) (Template, error) {
	if !t.Goal.Valid() {
		return Template{}, &ValidationError{"goal", "неизвестная цель"}
	}
	if err := t.Prefs.Validate(t.Goal); err != nil {
		return Template{}, &ValidationError{"prefs", err.Error()}
	}
	if n := utf8.RuneCountInString(strings.TrimSpace(t.Name)); n < 1 || n > 50 {
		return Template{}, &ValidationError{"name", "название от 1 до 50 символов"}
	}
	if t.MinScore == 0 {
		t.MinScore = DefaultMinScore
	}
	if t.DailyLimit == 0 {
		t.DailyLimit = DefaultDailyCap
	}
	if t.MinScore < 1 || t.MinScore > 100 || t.DailyLimit < 1 || t.DailyLimit > maxDailyCapLimit {
		return Template{}, &ValidationError{"limits", "порог 1–100, уведомлений в день 1–20"}
	}
	from, to, err := parseQuiet(t.QuietFrom, t.QuietTo)
	if err != nil {
		return Template{}, err
	}
	var n int
	if err := s.DB.QueryRow(ctx, `SELECT count(*) FROM search_templates WHERE user_id = $1`, userID).Scan(&n); err != nil {
		return Template{}, err
	}
	if n >= MaxTemplates {
		return Template{}, &ValidationError{"templates", "не больше 10 шаблонов"}
	}
	prefs, _ := json.Marshal(t.Prefs)
	err = s.DB.QueryRow(ctx, `INSERT INTO search_templates (user_id, goal, name, prefs, notify_nearby, min_score, daily_limit, quiet_from, quiet_to)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8::text::time, $9::text::time) RETURNING id`,
		userID, t.Goal, strings.TrimSpace(t.Name), prefs, t.NotifyNearby, t.MinScore, t.DailyLimit, from, to).Scan(&t.ID)
	return t, err
}

// Templates — шаблоны пользователя.
func (s *Service) Templates(ctx context.Context, userID string) ([]Template, error) {
	rows, err := s.DB.Query(ctx, `SELECT id, goal, name, prefs, notify_nearby, min_score, daily_limit,
		coalesce(to_char(quiet_from, 'HH24:MI'), ''), coalesce(to_char(quiet_to, 'HH24:MI'), '')
		FROM search_templates WHERE user_id = $1 ORDER BY created_at`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Template{}
	for rows.Next() {
		var t Template
		var raw []byte
		if err := rows.Scan(&t.ID, &t.Goal, &t.Name, &raw, &t.NotifyNearby, &t.MinScore, &t.DailyLimit, &t.QuietFrom, &t.QuietTo); err != nil {
			return nil, err
		}
		_ = json.Unmarshal(raw, &t.Prefs)
		out = append(out, t)
	}
	return out, rows.Err()
}

// DeleteTemplate удаляет шаблон.
func (s *Service) DeleteTemplate(ctx context.Context, userID, id string) error {
	_, err := s.DB.Exec(ctx, `DELETE FROM search_templates WHERE user_id = $1 AND id::text = $2`, userID, id)
	return err
}

func parseQuiet(from, to string) (*string, *string, error) {
	if from == "" && to == "" {
		return nil, nil, nil
	}
	for _, v := range []string{from, to} {
		if _, err := time.Parse("15:04", v); err != nil {
			return nil, nil, &ValidationError{"quiet", "тихие часы в формате ЧЧ:ММ, оба значения"}
		}
	}
	return &from, &to, nil
}

// inQuiet — попадает ли местное время в тихие часы (через полночь тоже).
func inQuiet(local time.Time, from, to string) bool {
	if from == "" || to == "" {
		return false
	}
	f, _ := time.Parse("15:04", from)
	t, _ := time.Parse("15:04", to)
	m := local.Hour()*60 + local.Minute()
	fm, tm := f.Hour()*60+f.Minute(), t.Hour()*60+t.Minute()
	if fm <= tm {
		return m >= fm && m < tm
	}
	return m >= fm || m < tm
}

// RunNotifications проходит по шаблонам с уведомлениями и сообщает о
// подходящих людях рядом. Вызывается раз в минуту. Возвращает число push.
func (s *Service) RunNotifications(ctx context.Context) (int, error) {
	rows, err := s.DB.Query(ctx, `
		SELECT t.user_id, t.goal, t.prefs, t.min_score, t.daily_limit,
		       coalesce(to_char(t.quiet_from, 'HH24:MI'), ''), coalesce(to_char(t.quiet_to, 'HH24:MI'), ''), p.timezone
		FROM search_templates t JOIN profiles p ON p.user_id = t.user_id
		JOIN users u ON u.id = t.user_id AND u.deleted_at IS NULL
		WHERE t.notify_nearby
		ORDER BY t.user_id, t.min_score DESC`)
	if err != nil {
		return 0, err
	}
	type job struct {
		userID     string
		goal       matching.Goal
		prefs      matching.Prefs
		minScore   int
		dailyLimit int
		quietFrom  string
		quietTo    string
		tz         string
	}
	var jobs []job
	for rows.Next() {
		var j job
		var raw []byte
		if err := rows.Scan(&j.userID, &j.goal, &raw, &j.minScore, &j.dailyLimit, &j.quietFrom, &j.quietTo, &j.tz); err != nil {
			rows.Close()
			return 0, err
		}
		if err := json.Unmarshal(raw, &j.prefs); err != nil {
			continue
		}
		jobs = append(jobs, j)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}

	sent := 0
	now := s.now()
	for _, j := range jobs {
		if _, ok, err := s.st().get(ctx, j.userID); err != nil || !ok {
			continue // нет свежей позиции — человек не в «Рядом»
		}
		loc, err := time.LoadLocation(j.tz)
		if err != nil {
			loc = time.UTC
		}
		local := now.In(loc)
		if inQuiet(local, j.quietFrom, j.quietTo) {
			continue
		}
		midnight := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, loc)
		var today int
		if err := s.DB.QueryRow(ctx, `SELECT count(*) FROM nearby_notifications WHERE user_id = $1 AND sent_at >= $2`,
			j.userID, midnight).Scan(&today); err != nil {
			return sent, err
		}
		if today >= j.dailyLimit {
			continue
		}
		prefs := j.prefs
		cards, err := s.nearbyCards(ctx, j.userID, j.goal, &prefs)
		if errors.Is(err, ErrNotVisible) || errors.Is(err, ErrNoLocation) || errors.Is(err, feed.ErrGoalNotActive) {
			continue
		}
		if err != nil {
			return sent, err
		}
		for _, c := range cards {
			if today >= j.dailyLimit {
				break
			}
			if c.Score < j.minScore {
				continue
			}
			var recent bool
			if err := s.DB.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM nearby_notifications
				WHERE user_id = $1 AND other_user = $2 AND sent_at > $3)`, j.userID, c.UserID, now.Add(-RepeatAfter)).Scan(&recent); err != nil {
				return sent, err
			}
			if recent {
				continue
			}
			if err := s.Push.Push(ctx, j.userID, "Рядом — свои люди", NotificationText(c)); err != nil {
				return sent, err
			}
			if _, err := s.DB.Exec(ctx, `INSERT INTO nearby_notifications (user_id, other_user, sent_at) VALUES ($1, $2, $3)`,
				j.userID, c.UserID, now); err != nil {
				return sent, err
			}
			today++
			sent++
		}
	}
	return sent, nil
}

// NotificationText — текст уведомления без личных данных:
// «До 1 км — человек с 3 общими интересами: эндуро, бонсай, садоводство».
func NotificationText(c feed.Card) string {
	n := len(c.Shared)
	dist := c.Distance
	if dist != "" {
		r, size := utf8.DecodeRuneInString(dist)
		dist = string(unicode.ToUpper(r)) + dist[size:]
	} else {
		dist = "Рядом"
	}
	if n == 0 {
		return dist + " — человек с похожими увлечениями"
	}
	var names []string
	for i, sh := range c.Shared {
		if i == 3 {
			break
		}
		names = append(names, lower(sh.Name))
	}
	return fmt.Sprintf("%s — человек с %d %s: %s", dist, n, pluralInstr(n), strings.Join(names, ", "))
}

// pluralInstr — «с 1 общим интересом», «с 3 общими интересами».
func pluralInstr(n int) string {
	if n%10 == 1 && n%100 != 11 {
		return "общим интересом"
	}
	return "общими интересами"
}

func lower(s string) string {
	r, size := utf8.DecodeRuneInString(s)
	next, _ := utf8.DecodeRuneInString(s[size:])
	if unicode.IsUpper(next) || !unicode.Is(unicode.Cyrillic, r) {
		return s
	}
	return string(unicode.ToLower(r)) + s[size:]
}
