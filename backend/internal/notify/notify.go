// Package notify — push-уведомления: о взаимном интересе, новом сообщении и людях рядом.
//
// По умолчанию на экране блокировки нет ни имени, ни текста — только «Новое сообщение»:
// телефон могут увидеть чужие люди. Показывать подробности человек включает сам.
package notify

import (
	"context"
	"errors"
	"log/slog"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Kind — тип уведомления; у каждого свой переключатель.
type Kind string

const (
	KindMatch   Kind = "match"
	KindMessage Kind = "message"
	KindNearby  Kind = "nearby"
	KindVerify  Kind = "verify"
)

// Message — одно уведомление. Data приложение получает при нажатии (куда открыть).
type Message struct {
	Kind  Kind
	Title string
	Body  string
	Data  map[string]string
}

// ErrBadToken — токен устройства больше не действует, его надо забыть.
var ErrBadToken = errors.New("notify: токен устройства недействителен")

// Sender доставляет уведомление на одно устройство.
type Sender interface {
	Send(ctx context.Context, token string, m Message) error
}

// LogSender — для разработки: пишет в журнал вместо отправки.
type LogSender struct{ Log *slog.Logger }

func (l LogSender) Send(_ context.Context, token string, m Message) error {
	l.Log.Info("DEV: push", "kind", m.Kind, "title", m.Title, "body", m.Body, "data", m.Data, "token", short(token))
	return nil
}

func short(t string) string {
	if len(t) > 8 {
		return t[:8] + "…"
	}
	return t
}

// Settings — что присылать.
type Settings struct {
	Matches  bool `json:"matches"`
	Messages bool `json:"messages"`
	Nearby   bool `json:"nearby"`
	// ShowText — имя и текст сообщения прямо в уведомлении.
	ShowText bool `json:"show_text"`
}

// DefaultSettings — без строки в базе.
var DefaultSettings = Settings{Matches: true, Messages: true, Nearby: true}

// MessageGap — о новых сообщениях в одном разговоре напоминаем не чаще раза в этот срок:
// десять сообщений подряд — одно уведомление.
const MessageGap = 30 * time.Second

// Service — уведомления.
type Service struct {
	DB     *pgxpool.Pool
	Sender Sender
	Log    *slog.Logger
	// Sync — отправлять в том же запросе (для тестов). Обычно отправка идёт в фоне,
	// чтобы медленный сервер уведомлений не задерживал ответ приложению.
	Sync bool
	Now  func() time.Time

	mu   sync.Mutex
	last map[string]time.Time // получатель+разговор → когда напоминали
	wg   sync.WaitGroup
}

func (s *Service) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// SetToken запоминает устройство. Токен, уже привязанный к другому аккаунту
// (вышли и вошли под другим номером), переезжает: уведомления идут только текущему.
func (s *Service) SetToken(ctx context.Context, userID, token, provider string) error {
	if provider == "" {
		provider = "rustore"
	}
	if token == "" || len(token) > 4096 || provider != "rustore" {
		return ErrBadToken
	}
	_, err := s.DB.Exec(ctx, `INSERT INTO push_tokens (token, user_id, provider) VALUES ($1, $2, $3)
		ON CONFLICT (token) DO UPDATE SET user_id = $2, provider = $3, updated_at = now()`, token, userID, provider)
	return err
}

// DeleteToken — устройство больше не получает уведомления этого аккаунта (выход).
func (s *Service) DeleteToken(ctx context.Context, userID, token string) error {
	_, err := s.DB.Exec(ctx, `DELETE FROM push_tokens WHERE token = $1 AND user_id = $2`, token, userID)
	return err
}

// Get — настройки человека.
func (s *Service) Get(ctx context.Context, userID string) (Settings, error) {
	st := DefaultSettings
	err := s.DB.QueryRow(ctx, `SELECT matches, messages, nearby, show_text FROM notification_settings WHERE user_id = $1`,
		userID).Scan(&st.Matches, &st.Messages, &st.Nearby, &st.ShowText)
	if errors.Is(err, pgx.ErrNoRows) {
		return DefaultSettings, nil
	}
	return st, err
}

// Set сохраняет настройки.
func (s *Service) Set(ctx context.Context, userID string, st Settings) error {
	_, err := s.DB.Exec(ctx, `INSERT INTO notification_settings (user_id, matches, messages, nearby, show_text)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (user_id) DO UPDATE SET matches = $2, messages = $3, nearby = $4, show_text = $5`,
		userID, st.Matches, st.Messages, st.Nearby, st.ShowText)
	return err
}

// Matched — второй человек узнаёт о взаимном интересе (первый видит экран совпадения сразу).
func (s *Service) Matched(ctx context.Context, matchID, actorID string) {
	s.run(ctx, func(ctx context.Context) error {
		other, name, err := s.pair(ctx, matchID, actorID)
		if err != nil {
			return err
		}
		return s.deliver(ctx, other, func(st Settings) *Message {
			if !st.Matches {
				return nil
			}
			body := "Можно начать разговор"
			if st.ShowText {
				body = name + " — можно начать разговор"
			}
			return &Message{Kind: KindMatch, Title: "Взаимный интерес", Body: body,
				Data: map[string]string{"type": "match", "match_id": matchID}}
		})
	})
}

// MessageSent — получатель узнаёт о новом сообщении.
func (s *Service) MessageSent(ctx context.Context, matchID, senderID, text string) {
	s.run(ctx, func(ctx context.Context) error {
		other, name, err := s.pair(ctx, matchID, senderID)
		if err != nil {
			return err
		}
		key := other + "/" + matchID
		now := s.now()
		s.mu.Lock()
		if s.last == nil {
			s.last = map[string]time.Time{}
		}
		recent := now.Sub(s.last[key]) < MessageGap
		if !recent {
			s.last[key] = now
		}
		s.mu.Unlock()
		if recent {
			return nil
		}
		return s.deliver(ctx, other, func(st Settings) *Message {
			if !st.Messages {
				return nil
			}
			m := &Message{Kind: KindMessage, Title: "Новое сообщение", Body: "Откройте, чтобы прочитать",
				Data: map[string]string{"type": "message", "match_id": matchID}}
			if st.ShowText {
				m.Title, m.Body = name, cut(text, 120)
			}
			return m
		})
	})
}

// Verified — итог проверки по селфи. Приходит всегда: человек ждёт ответа.
func (s *Service) Verified(ctx context.Context, userID string, approved bool) {
	s.run(ctx, func(ctx context.Context) error {
		return s.deliver(ctx, userID, func(Settings) *Message {
			m := &Message{Kind: KindVerify, Title: "Фото проверено", Body: "Теперь у анкеты есть значок проверки",
				Data: map[string]string{"type": "verify"}}
			if !approved {
				m.Title, m.Body = "Проверка фото не пройдена", "Откройте профиль — там причина и новая попытка"
			}
			return m
		})
	})
}

// Push — уведомление «Рядом» (интерфейс nearby.Pusher).
func (s *Service) Push(ctx context.Context, userID, title, body string) error {
	return s.deliver(ctx, userID, func(st Settings) *Message {
		if !st.Nearby {
			return nil
		}
		return &Message{Kind: KindNearby, Title: title, Body: body, Data: map[string]string{"type": "nearby"}}
	})
}

// Wait дожидается фоновых отправок (при остановке сервера и в тестах).
func (s *Service) Wait() { s.wg.Wait() }

func (s *Service) run(ctx context.Context, fn func(context.Context) error) {
	if s.Sync {
		if err := fn(ctx); err != nil {
			s.logErr(err)
		}
		return
	}
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 20*time.Second)
		defer cancel()
		if err := fn(ctx); err != nil {
			s.logErr(err)
		}
	}()
}

func (s *Service) logErr(err error) {
	if s.Log != nil {
		s.Log.Error("уведомление не отправлено", "err", err)
	}
}

// pair — второй участник разговора и имя первого.
func (s *Service) pair(ctx context.Context, matchID, actorID string) (other, actorName string, err error) {
	err = s.DB.QueryRow(ctx, `
		SELECT CASE WHEN m.user_a = $2 THEN m.user_b ELSE m.user_a END, coalesce(p.display_name, '')
		FROM matches m LEFT JOIN profiles p ON p.user_id = $2
		WHERE m.id = $1 AND (m.user_a = $2 OR m.user_b = $2)`, matchID, actorID).Scan(&other, &actorName)
	return other, actorName, err
}

// deliver отправляет на все устройства человека; недействительные токены забывает.
func (s *Service) deliver(ctx context.Context, userID string, build func(Settings) *Message) error {
	st, err := s.Get(ctx, userID)
	if err != nil {
		return err
	}
	m := build(st)
	if m == nil || s.Sender == nil {
		return nil
	}
	rows, err := s.DB.Query(ctx, `SELECT token FROM push_tokens WHERE user_id = $1`, userID)
	if err != nil {
		return err
	}
	tokens, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return err
	}
	var firstErr error
	for _, t := range tokens {
		err := s.Sender.Send(ctx, t, *m)
		if errors.Is(err, ErrBadToken) {
			_, err = s.DB.Exec(ctx, `DELETE FROM push_tokens WHERE token = $1`, t)
		}
		if err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

func cut(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	r := []rune(s)
	return string(r[:n-1]) + "…"
}
