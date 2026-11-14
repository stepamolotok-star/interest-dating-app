// Package moderation — разбор жалоб: очередь для модератора, решения
// (отклонить, предупредить, заблокировать на время или навсегда) и автоматическое
// скрытие человека до проверки, если на него пожаловались несколько разных людей.
package moderation

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/auth"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/contacts"
)

// Решения модератора по жалобе.
const (
	Dismiss = "dismiss" // жалоба не подтвердилась
	Warn    = "warn"    // предупреждение: человек увидит текст при следующем входе
	Suspend = "suspend" // вход закрыт на N дней, из ленты и «Рядом» скрыт
	Ban     = "ban"     // навсегда; номер больше не зарегистрировать
)

// Порог автоскрытия: столько разных людей за 7 дней пожаловались на угрозы,
// преследование или слежку — человек скрыт из ленты и «Рядом» до решения модератора.
const (
	HoldUrgentReporters = 3
	HoldMinorReporters  = 2 // «похоже на несовершеннолетнего» — порог ниже
	HoldWindow          = 7 * 24 * time.Hour
	MaxSuspendDays      = 90
	DefaultWarning      = "Модератор получил жалобы на ваше поведение. Пожалуйста, соблюдайте правила: " +
		"уважительное общение, без угроз, навязчивости и рекламы. При повторных нарушениях аккаунт заблокируют."
)

var (
	ErrNotFound      = errors.New("жалоба не найдена")
	ErrAlreadyClosed = errors.New("по этой жалобе уже принято решение")
	ErrBadAction     = errors.New("неизвестное решение")
	ErrBadDays       = errors.New("срок блокировки — от 1 до 90 дней")
	ErrUserNotFound  = errors.New("пользователь не найден")
)

// Hider убирает человека из «Рядом» (видимость выключается сразу).
type Hider interface {
	Disappear(ctx context.Context, userID string) error
}

// Service — модерация.
type Service struct {
	DB *pgxpool.Pool
	// PhoneSecret — тот же ключ, что у phone_key (contacts): по нему номер попадает в banned_phones.
	PhoneSecret []byte
	Nearby      Hider
	Now         func() time.Time
}

func (s *Service) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// Person — кратко о человеке для модератора.
type Person struct {
	ID             string     `json:"id"`
	Name           string     `json:"name"`
	Age            int        `json:"age"`
	City           string     `json:"city"`
	About          string     `json:"about,omitempty"`
	Prompts        []Prompt   `json:"prompts,omitempty"`
	RegisteredAt   time.Time  `json:"registered_at"`
	BannedAt       *time.Time `json:"banned_at,omitempty"`
	SuspendedUntil *time.Time `json:"suspended_until,omitempty"`
	OnHold         bool       `json:"on_hold"`
}

type Prompt struct {
	Question string `json:"question"`
	Answer   string `json:"answer"`
}

// Report — жалоба в очереди.
type Report struct {
	ID         int64      `json:"id"`
	Reason     string     `json:"reason"`
	Urgent     bool       `json:"urgent"`
	Comment    string     `json:"comment,omitempty"`
	Status     string     `json:"status"`
	Resolution string     `json:"resolution,omitempty"`
	Moderator  string     `json:"moderator,omitempty"`
	CreatedAt  time.Time  `json:"created_at"`
	ResolvedAt *time.Time `json:"resolved_at,omitempty"`
	Reporter   Person     `json:"reporter"`
	Target     Person     `json:"target"`
	// Сколько разных людей жаловались на этого человека за 30 дней.
	TargetReporters int `json:"target_reporters"`
}

// Message — сообщение из переписки жалобщика и нарушителя.
type Message struct {
	Sender    string    `json:"sender"` // reporter / target
	Body      string    `json:"body"`
	CreatedAt time.Time `json:"created_at"`
}

// Action — прошлое решение по человеку.
type Action struct {
	Action    string     `json:"action"`
	Moderator string     `json:"moderator"`
	Note      string     `json:"note,omitempty"`
	Until     *time.Time `json:"until,omitempty"`
	CreatedAt time.Time  `json:"created_at"`
}

// Detail — всё, что нужно для решения по жалобе.
type Detail struct {
	Report
	Messages     []Message `json:"messages"`
	OtherReports []Report  `json:"other_reports"`
	History      []Action  `json:"history"`
}

const reportSelect = `
	SELECT r.id, r.reason, r.urgent, coalesce(r.comment, ''), r.status, coalesce(r.resolution, ''),
	       coalesce(r.moderator, ''), r.created_at, r.resolved_at,
	       r.reporter, coalesce(rp.display_name, '—'),
	       r.target, coalesce(tp.display_name, '—'), tu.birth_date, coalesce(tp.city, ''),
	       coalesce(tp.about, ''), coalesce(tp.prompts, '[]'::jsonb), tu.created_at,
	       tu.banned_at, tu.suspended_until, tu.on_hold,
	       (SELECT count(DISTINCT x.reporter) FROM reports x
	         WHERE x.target = r.target AND x.created_at > now() - interval '30 days')
	FROM reports r
	JOIN users tu ON tu.id = r.target
	LEFT JOIN profiles tp ON tp.user_id = r.target
	LEFT JOIN profiles rp ON rp.user_id = r.reporter`

func (s *Service) scanReports(rows pgx.Rows) ([]Report, error) {
	defer rows.Close()
	out := []Report{}
	now := s.now()
	for rows.Next() {
		var r Report
		var birth time.Time
		var prompts []byte
		if err := rows.Scan(&r.ID, &r.Reason, &r.Urgent, &r.Comment, &r.Status, &r.Resolution,
			&r.Moderator, &r.CreatedAt, &r.ResolvedAt,
			&r.Reporter.ID, &r.Reporter.Name,
			&r.Target.ID, &r.Target.Name, &birth, &r.Target.City,
			&r.Target.About, &prompts, &r.Target.RegisteredAt,
			&r.Target.BannedAt, &r.Target.SuspendedUntil, &r.Target.OnHold,
			&r.TargetReporters); err != nil {
			return nil, err
		}
		r.Target.Age = auth.Age(birth, now)
		_ = json.Unmarshal(prompts, &r.Target.Prompts)
		out = append(out, r)
	}
	return out, rows.Err()
}

// Queue — жалобы: сначала срочные, потом по времени. status: open (по умолчанию) или closed.
func (s *Service) Queue(ctx context.Context, status string, limit int) ([]Report, error) {
	if limit <= 0 || limit > 200 {
		limit = 100
	}
	where, order := `r.status IN ('open','in_review')`, `r.urgent DESC, r.created_at`
	if status == "closed" {
		where, order = `r.status IN ('resolved','rejected')`, `r.resolved_at DESC`
	}
	rows, err := s.DB.Query(ctx, reportSelect+` WHERE `+where+` ORDER BY `+order+` LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	return s.scanReports(rows)
}

// Get — жалоба с перепиской, другими жалобами на того же человека и прошлыми решениями.
func (s *Service) Get(ctx context.Context, id int64) (Detail, error) {
	rows, err := s.DB.Query(ctx, reportSelect+` WHERE r.id = $1`, id)
	if err != nil {
		return Detail{}, err
	}
	list, err := s.scanReports(rows)
	if err != nil {
		return Detail{}, err
	}
	if len(list) == 0 {
		return Detail{}, ErrNotFound
	}
	d := Detail{Report: list[0], Messages: []Message{}, History: []Action{}}

	// Переписка только этой пары — модератор не видит чужих разговоров.
	mrows, err := s.DB.Query(ctx, `
		SELECT CASE WHEN m.sender = $1 THEN 'reporter' ELSE 'target' END, coalesce(m.body, ''), m.created_at
		FROM messages m JOIN matches mt ON mt.id = m.match_id
		WHERE m.kind = 'text' AND m.sender IN ($1, $2)
		  AND ((mt.user_a = $1 AND mt.user_b = $2) OR (mt.user_a = $2 AND mt.user_b = $1))
		ORDER BY m.created_at DESC LIMIT 50`, d.Reporter.ID, d.Target.ID)
	if err != nil {
		return Detail{}, err
	}
	for mrows.Next() {
		var m Message
		if err := mrows.Scan(&m.Sender, &m.Body, &m.CreatedAt); err != nil {
			mrows.Close()
			return Detail{}, err
		}
		d.Messages = append(d.Messages, m)
	}
	mrows.Close()
	// Хронологически — так читать переписку привычнее.
	for i, j := 0, len(d.Messages)-1; i < j; i, j = i+1, j-1 {
		d.Messages[i], d.Messages[j] = d.Messages[j], d.Messages[i]
	}

	orows, err := s.DB.Query(ctx, reportSelect+` WHERE r.target = $1 AND r.id <> $2 ORDER BY r.created_at DESC LIMIT 20`,
		d.Target.ID, id)
	if err != nil {
		return Detail{}, err
	}
	if d.OtherReports, err = s.scanReports(orows); err != nil {
		return Detail{}, err
	}

	hrows, err := s.DB.Query(ctx, `SELECT action, moderator, coalesce(note, ''), until, created_at
		FROM moderation_actions WHERE target = $1 ORDER BY created_at DESC LIMIT 20`, d.Target.ID)
	if err != nil {
		return Detail{}, err
	}
	defer hrows.Close()
	for hrows.Next() {
		var a Action
		if err := hrows.Scan(&a.Action, &a.Moderator, &a.Note, &a.Until, &a.CreatedAt); err != nil {
			return Detail{}, err
		}
		d.History = append(d.History, a)
	}
	return d, hrows.Err()
}

// Resolve — решение по жалобе. Для warn/suspend/ban закрываются и все остальные
// открытые жалобы на этого человека: решение принято по нему, а не по одной жалобе.
func (s *Service) Resolve(ctx context.Context, reportID int64, moderator, action string, days int, note string) error {
	moderator = clip(strings.TrimSpace(moderator), 60)
	if moderator == "" {
		moderator = "модератор"
	}
	note = clip(strings.TrimSpace(note), 1000)
	switch action {
	case Dismiss, Warn, Ban:
	case Suspend:
		if days < 1 || days > MaxSuspendDays {
			return ErrBadDays
		}
	default:
		return ErrBadAction
	}
	now := s.now()

	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	var target, status string
	err = tx.QueryRow(ctx, `SELECT target, status FROM reports WHERE id = $1 FOR UPDATE`, reportID).Scan(&target, &status)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	if status == "resolved" || status == "rejected" {
		return ErrAlreadyClosed
	}

	var until *time.Time
	hide := false
	switch action {
	case Dismiss:
		if _, err := tx.Exec(ctx, `UPDATE reports SET status = 'rejected', resolution = $2, moderator = $3, resolved_at = $4
			WHERE id = $1`, reportID, Dismiss, moderator, now); err != nil {
			return err
		}
		// Снимаем автоскрытие, если других открытых жалоб не осталось.
		if _, err := tx.Exec(ctx, `UPDATE users SET on_hold = false WHERE id = $1 AND NOT EXISTS (
			SELECT 1 FROM reports WHERE target = $1 AND status IN ('open','in_review'))`, target); err != nil {
			return err
		}
	case Warn:
		// Комментарий модератора вставляем в готовую рамку: человек видит текст как есть.
		text := DefaultWarning
		if note != "" {
			text = "Модератор проверил жалобы на вас: «" + note + "». При повторных нарушениях аккаунт заблокируют."
		}
		if _, err := tx.Exec(ctx, `UPDATE users SET warning = $2, warned_at = $3, on_hold = false WHERE id = $1`,
			target, text, now); err != nil {
			return err
		}
	case Suspend:
		t := now.Add(time.Duration(days) * 24 * time.Hour)
		until, hide = &t, true
		if _, err := tx.Exec(ctx, `UPDATE users SET suspended_until = $2, ban_reason = $3, on_hold = false WHERE id = $1`,
			target, t, nullable(note)); err != nil {
			return err
		}
	case Ban:
		hide = true
		var phone string
		if err := tx.QueryRow(ctx, `UPDATE users SET banned_at = $2, ban_reason = $3, on_hold = false WHERE id = $1
			RETURNING phone_e164`, target, now, nullable(note)).Scan(&phone); err != nil {
			return err
		}
		reason := note
		if reason == "" {
			reason = "блокировка по жалобе"
		}
		if _, err := tx.Exec(ctx, `INSERT INTO banned_phones (phone_key, reason) VALUES ($1, $2)
			ON CONFLICT (phone_key) DO NOTHING`, contacts.PhoneKey(s.PhoneSecret, phone), reason); err != nil {
			return err
		}
		// Все совпадения закрываются, «Интересно» от него больше никого не ждут.
		if _, err := tx.Exec(ctx, `UPDATE matches SET ended_at = $2 WHERE ended_at IS NULL AND (user_a = $1 OR user_b = $1)`,
			target, now); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `DELETE FROM interests_expressed WHERE from_user = $1`, target); err != nil {
			return err
		}
	}
	if action != Dismiss {
		if _, err := tx.Exec(ctx, `UPDATE reports SET status = 'resolved', resolution = $2, moderator = $3, resolved_at = $4
			WHERE target = $1 AND status IN ('open','in_review')`, target, action, moderator, now); err != nil {
			return err
		}
	}
	// Сессии не отзываем: каждый запрос всё равно проверяет блокировку (auth.Authenticate),
	// а с живой сессией приложение сразу покажет экран «аккаунт заблокирован» со сроком,
	// а не «войдите заново». После срока блокировки человек продолжит без повторного входа.
	if _, err := tx.Exec(ctx, `INSERT INTO moderation_actions (target, action, report_id, moderator, note, until)
		VALUES ($1, $2, $3, $4, $5, $6)`, target, action, reportID, moderator, nullable(note), until); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	if hide && s.Nearby != nil {
		return s.Nearby.Disappear(ctx, target)
	}
	return nil
}

// Unban снимает блокировку (навсегда или временную) и возвращает номер.
func (s *Service) Unban(ctx context.Context, userID, moderator, note string) error {
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	var phone string
	err = tx.QueryRow(ctx, `UPDATE users SET banned_at = NULL, ban_reason = NULL, suspended_until = NULL, on_hold = false
		WHERE id = $1 RETURNING phone_e164`, userID).Scan(&phone)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrUserNotFound
	}
	if err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM banned_phones WHERE phone_key = $1`, contacts.PhoneKey(s.PhoneSecret, phone)); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO moderation_actions (target, action, moderator, note) VALUES ($1, 'unban', $2, $3)`,
		userID, clip(strings.TrimSpace(moderator), 60), nullable(clip(strings.TrimSpace(note), 1000))); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// AfterReport вызывается после каждой жалобы: если разные люди жалуются на одно и то же
// срочное (угрозы, преследование, слежка, несовершеннолетний), человек скрывается из ленты
// и «Рядом» до решения модератора. Сам он об этом не узнаёт и пользуется приложением как обычно.
func (s *Service) AfterReport(ctx context.Context, target string) (held bool, err error) {
	var urgent, minor int
	since := s.now().Add(-HoldWindow)
	if err := s.DB.QueryRow(ctx, `
		SELECT count(DISTINCT reporter) FILTER (WHERE urgent),
		       count(DISTINCT reporter) FILTER (WHERE reason = 'minor')
		FROM reports WHERE target = $1 AND created_at > $2 AND status IN ('open','in_review')`,
		target, since).Scan(&urgent, &minor); err != nil {
		return false, err
	}
	if urgent < HoldUrgentReporters && minor < HoldMinorReporters {
		return false, nil
	}
	tag, err := s.DB.Exec(ctx, `UPDATE users SET on_hold = true WHERE id = $1 AND NOT on_hold`, target)
	if err != nil {
		return false, err
	}
	if tag.RowsAffected() == 0 {
		return true, nil
	}
	if _, err := s.DB.Exec(ctx, `INSERT INTO moderation_actions (target, action, moderator, note)
		VALUES ($1, 'hold', 'авто', 'несколько срочных жалоб от разных людей')`, target); err != nil {
		return true, err
	}
	if s.Nearby != nil {
		return true, s.Nearby.Disappear(ctx, target)
	}
	return true, nil
}

// Stats — счётчики для шапки страницы модератора.
type Stats struct {
	Open    int `json:"open"`
	Urgent  int `json:"urgent"`
	OnHold  int `json:"on_hold"`
	Banned  int `json:"banned"`
	Blocked int `json:"suspended"`
}

func (s *Service) Stats(ctx context.Context) (Stats, error) {
	var st Stats
	err := s.DB.QueryRow(ctx, `
		SELECT (SELECT count(*) FROM reports WHERE status IN ('open','in_review')),
		       (SELECT count(*) FROM reports WHERE status IN ('open','in_review') AND urgent),
		       (SELECT count(*) FROM users WHERE on_hold),
		       (SELECT count(*) FROM users WHERE banned_at IS NOT NULL),
		       (SELECT count(*) FROM users WHERE suspended_until > now())`).
		Scan(&st.Open, &st.Urgent, &st.OnHold, &st.Banned, &st.Blocked)
	return st, err
}

func nullable(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func clip(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n])
}
