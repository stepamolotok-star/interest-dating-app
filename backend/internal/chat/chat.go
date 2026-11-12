// Package chat — совпадения, переписка и безопасность общения:
// «Разорвать совпадение», блокировка и жалобы.
//
// Совпадение раскрывает профиль до уровня 1 (имя, точный возраст, поля
// «после совпадения»). Разрыв или блокировка закрывают доступ сразу и
// для обоих: переписку больше не видит никто из двоих.
package chat

import (
	"context"
	"encoding/json"
	"errors"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/catalog"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/profile"
)

// Ограничения.
const (
	MaxMessageLen = 2000
	PageSize      = 50
)

// Ошибки.
var (
	ErrNotFound        = errors.New("переписка не найдена или закрыта")
	ErrEmpty           = errors.New("пустое сообщение")
	ErrTooLong         = errors.New("сообщение длиннее 2000 символов")
	ErrContactsInHello = errors.New("в первом сообщении нельзя оставлять ссылки и контакты — так часто действуют мошенники. Познакомьтесь сначала здесь")
	ErrBadReason       = errors.New("неизвестная причина жалобы")
)

// ReportReasons — допустимые причины жалобы (срочные: угрозы, преследование, слежка,
// подозрение, что человек несовершеннолетний).
var ReportReasons = []string{"threat", "harassment", "stalking", "minor", "fake", "spam", "paid_services", "explicit", "other"}

// Service — чат и безопасность.
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

// Person — раскрытый после совпадения профиль собеседника (уровень 1).
type Person struct {
	UserID    string           `json:"user_id"`
	Name      string           `json:"name"`
	Age       int              `json:"age"`
	About     string           `json:"about,omitempty"`
	Prompts   []profile.Prompt `json:"prompts,omitempty"`
	Interests []string         `json:"interests"`
}

// MatchSummary — строка в списке совпадений.
type MatchSummary struct {
	MatchID     string    `json:"match_id"`
	Goal        string    `json:"goal"`
	CreatedAt   time.Time `json:"created_at"`
	Other       Person    `json:"other"`
	LastMessage *Message  `json:"last_message,omitempty"`
}

// Message — сообщение.
type Message struct {
	ID        int64     `json:"id"`
	Sender    string    `json:"sender"`
	Kind      string    `json:"kind"`
	Body      string    `json:"body"`
	CreatedAt time.Time `json:"created_at"`
}

// Matches — активные совпадения пользователя, свежая переписка сверху.
func (s *Service) Matches(ctx context.Context, userID string) ([]MatchSummary, error) {
	rows, err := s.DB.Query(ctx, `
		SELECT m.id, m.goal, m.created_at,
		       CASE WHEN m.user_a = $1 THEN m.user_b ELSE m.user_a END AS other
		FROM matches m
		WHERE m.ended_at IS NULL AND (m.user_a = $1 OR m.user_b = $1)
		ORDER BY coalesce((SELECT max(created_at) FROM messages WHERE match_id = m.id), m.created_at) DESC`, userID)
	if err != nil {
		return nil, err
	}
	out := []MatchSummary{}
	for rows.Next() {
		var ms MatchSummary
		if err := rows.Scan(&ms.MatchID, &ms.Goal, &ms.CreatedAt, &ms.Other.UserID); err != nil {
			rows.Close()
			return nil, err
		}
		out = append(out, ms)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for i := range out {
		p, err := s.person(ctx, out[i].Other.UserID)
		if err != nil {
			return nil, err
		}
		out[i].Other = p
		var m Message
		err = s.DB.QueryRow(ctx, `SELECT id, sender, kind, coalesce(body, ''), created_at FROM messages
			WHERE match_id = $1 ORDER BY id DESC LIMIT 1`, out[i].MatchID).Scan(&m.ID, &m.Sender, &m.Kind, &m.Body, &m.CreatedAt)
		if err == nil {
			out[i].LastMessage = &m
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
	}
	if out == nil {
		out = []MatchSummary{}
	}
	return out, nil
}

// person — профиль уровня 1: только поля с видимостью «анонимно» или «после совпадения».
func (s *Service) person(ctx context.Context, userID string) (Person, error) {
	p := Person{UserID: userID, Interests: []string{}}
	var birth time.Time
	var prompts []byte
	err := s.DB.QueryRow(ctx, `SELECT p.display_name, u.birth_date, coalesce(p.about, ''), p.prompts
		FROM users u JOIN profiles p ON p.user_id = u.id WHERE u.id = $1`, userID).Scan(&p.Name, &birth, &p.About, &prompts)
	if err != nil {
		return Person{}, err
	}
	now := s.now()
	p.Age = now.Year() - birth.Year()
	if now.Month() < birth.Month() || (now.Month() == birth.Month() && now.Day() < birth.Day()) {
		p.Age--
	}
	vis := map[string]string{}
	for k, v := range profile.DefaultVisibility {
		vis[k] = v
	}
	rows, err := s.DB.Query(ctx, `SELECT field, visibility FROM profile_field_visibility WHERE user_id = $1`, userID)
	if err != nil {
		return Person{}, err
	}
	for rows.Next() {
		var f, v string
		if err := rows.Scan(&f, &v); err != nil {
			rows.Close()
			return Person{}, err
		}
		vis[f] = v
	}
	rows.Close()
	open := func(f string) bool { return vis[f] == profile.Anonymous || vis[f] == profile.AfterMatch }
	if !open("about") {
		p.About = ""
	}
	if open("prompts") {
		_ = json.Unmarshal(prompts, &p.Prompts)
	}
	ids, err := s.DB.Query(ctx, `SELECT interest_id FROM user_interests WHERE user_id = $1 ORDER BY interest_id`, userID)
	if err != nil {
		return Person{}, err
	}
	defer ids.Close()
	for ids.Next() {
		var id string
		if err := ids.Scan(&id); err != nil {
			return Person{}, err
		}
		p.Interests = append(p.Interests, s.Catalog.Name(id))
	}
	return p, ids.Err()
}

// member проверяет, что пользователь — участник активного совпадения.
func (s *Service) member(ctx context.Context, q interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}, userID, matchID string) error {
	if !validUUID(matchID) {
		return ErrNotFound
	}
	var ok bool
	err := q.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM matches WHERE id = $1 AND ended_at IS NULL
		AND (user_a = $2 OR user_b = $2))`, matchID, userID).Scan(&ok)
	if err != nil {
		return err
	}
	if !ok {
		return ErrNotFound
	}
	return nil
}

// Messages — страница переписки, от новых к старым. before = 0 — с конца.
func (s *Service) Messages(ctx context.Context, userID, matchID string, before int64) ([]Message, error) {
	if err := s.member(ctx, s.DB, userID, matchID); err != nil {
		return nil, err
	}
	q := `SELECT id, sender, kind, coalesce(body, ''), created_at FROM messages WHERE match_id = $1`
	args := []any{matchID}
	if before > 0 {
		q += ` AND id < $2`
		args = append(args, before)
	}
	q += ` ORDER BY id DESC LIMIT ` + strconv.Itoa(PageSize)
	rows, err := s.DB.Query(ctx, q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Message{}
	for rows.Next() {
		var m Message
		if err := rows.Scan(&m.ID, &m.Sender, &m.Kind, &m.Body, &m.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

var contactPattern = regexp.MustCompile(`(?i)(https?://|www\.|t\.me/|wa\.me/|vk\.com/|@[a-z0-9_]{4,}|\b[a-z0-9-]+\.(ru|com|me|org|net|рф)\b|телег|\btg\b|whatsapp|ватсап|вотсап|вацап|вайбер|viber|инстаграм|instagram|\+?[78][\s(-]*\d{3}[\s)-]*\d{3}[\s-]*\d{2}[\s-]*\d{2})`)

// HasContacts — есть ли в тексте ссылки, ники или номер телефона.
func HasContacts(text string) bool { return contactPattern.MatchString(text) }

// Send отправляет текстовое сообщение. В самом первом сообщении пары
// ссылки и контакты запрещены — типичная схема мошенников (ТЗ, раздел 8).
func (s *Service) Send(ctx context.Context, userID, matchID, body string) (Message, error) {
	body = strings.TrimSpace(body)
	if body == "" {
		return Message{}, ErrEmpty
	}
	if utf8.RuneCountInString(body) > MaxMessageLen {
		return Message{}, ErrTooLong
	}
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return Message{}, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if err := s.member(ctx, tx, userID, matchID); err != nil {
		return Message{}, err
	}
	var hasHistory bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM messages WHERE match_id = $1 AND kind <> 'system')`,
		matchID).Scan(&hasHistory); err != nil {
		return Message{}, err
	}
	if !hasHistory && HasContacts(body) {
		return Message{}, ErrContactsInHello
	}
	m := Message{Sender: userID, Kind: "text", Body: body}
	if err := tx.QueryRow(ctx, `INSERT INTO messages (match_id, sender, kind, body, created_at)
		VALUES ($1, $2, 'text', $3, $4) RETURNING id, created_at`, matchID, userID, body, s.now()).Scan(&m.ID, &m.CreatedAt); err != nil {
		return Message{}, err
	}
	if _, err := tx.Exec(ctx, `UPDATE users SET last_active_at = $2 WHERE id = $1`, userID, s.now()); err != nil {
		return Message{}, err
	}
	return m, tx.Commit(ctx)
}

// End — «Разорвать совпадение»: доступ к профилю и переписке закрывается сразу для обоих.
func (s *Service) End(ctx context.Context, userID, matchID string) error {
	if err := s.member(ctx, s.DB, userID, matchID); err != nil {
		return err
	}
	_, err := s.DB.Exec(ctx, `UPDATE matches SET ended_at = $3, ended_by = $2 WHERE id = $1 AND ended_at IS NULL`,
		matchID, userID, s.now())
	return err
}

// Block — блокировка: взаимная невидимость везде и разрыв всех совпадений пары.
func (s *Service) Block(ctx context.Context, blocker, blocked string) error {
	if blocker == blocked || !validUUID(blocked) {
		return ErrNotFound
	}
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	tag, err := tx.Exec(ctx, `INSERT INTO blocks (blocker, blocked) SELECT $1, id FROM users WHERE id = $2
		ON CONFLICT DO NOTHING`, blocker, blocked)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		var exists bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM users WHERE id = $1)`, blocked).Scan(&exists); err != nil {
			return err
		}
		if !exists {
			return ErrNotFound
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE matches SET ended_at = $3, ended_by = $1
		WHERE ended_at IS NULL AND ((user_a = $1 AND user_b = $2) OR (user_a = $2 AND user_b = $1))`, blocker, blocked, s.now()); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM interests_expressed
		WHERE (from_user = $1 AND to_user = $2) OR (from_user = $2 AND to_user = $1)`, blocker, blocked); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

// Report — жалоба. Угрозы, преследование и слежка помечаются срочными
// (рассмотрение до 1 часа). Возвращает, срочная ли жалоба.
func (s *Service) Report(ctx context.Context, reporter, target, reason, comment string) (urgent bool, err error) {
	if !slices.Contains(ReportReasons, reason) {
		return false, ErrBadReason
	}
	if reporter == target || !validUUID(target) {
		return false, ErrNotFound
	}
	if utf8.RuneCountInString(comment) > 1000 {
		comment = string([]rune(comment)[:1000])
	}
	err = s.DB.QueryRow(ctx, `INSERT INTO reports (reporter, target, reason, comment)
		SELECT $1, id, $3, nullif($4, '') FROM users WHERE id = $2 RETURNING urgent`,
		reporter, target, reason, comment).Scan(&urgent)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, ErrNotFound
	}
	return urgent, err
}

var uuidPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

func validUUID(s string) bool { return uuidPattern.MatchString(s) }
