package notify

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/stepamolotok-star/interest-dating-app/backend/migrations"
)

func TestRuStoreSender(t *testing.T) {
	var got map[string]any
	var auth, path string
	status := http.StatusOK
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth, path = r.Header.Get("Authorization"), r.URL.Path
		b, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(b, &got)
		w.WriteHeader(status)
		if status == http.StatusBadRequest {
			_, _ = w.Write([]byte(`{"error":{"code":400,"message":"The registration token is not a valid FCM registration token","status":"INVALID_ARGUMENT"}}`))
			return
		}
		_, _ = w.Write([]byte(`{}`))
	}))
	defer srv.Close()
	r := RuStore{ProjectID: "proj-1", Token: "srv-token", Base: srv.URL}
	m := Message{Kind: KindMessage, Title: "Новое сообщение", Body: "Откройте", Data: map[string]string{"match_id": "m1"}}
	if err := r.Send(context.Background(), "dev-token", m); err != nil {
		t.Fatal(err)
	}
	if path != "/v1/projects/proj-1/messages:send" || auth != "Bearer srv-token" {
		t.Fatalf("запрос: %s %s", path, auth)
	}
	msg := got["message"].(map[string]any)
	if msg["token"] != "dev-token" || msg["notification"].(map[string]any)["title"] != "Новое сообщение" ||
		msg["data"].(map[string]any)["match_id"] != "m1" || msg["data"].(map[string]any)["kind"] != "message" {
		t.Fatalf("тело: %v", got)
	}
	status = http.StatusNotFound
	if err := r.Send(context.Background(), "old", m); !errors.Is(err, ErrBadToken) {
		t.Fatalf("404: %v", err)
	}
	status = http.StatusBadRequest
	if err := r.Send(context.Background(), "bad", m); !errors.Is(err, ErrBadToken) {
		t.Fatalf("400: %v", err)
	}
	status = http.StatusInternalServerError
	if err := r.Send(context.Background(), "x", m); err == nil || errors.Is(err, ErrBadToken) {
		t.Fatalf("500: %v", err)
	}
}

type fakeSender struct {
	mu   sync.Mutex
	sent []sent
	bad  map[string]bool
}

type sent struct {
	token string
	m     Message
}

func (f *fakeSender) Send(_ context.Context, token string, m Message) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.bad[token] {
		return ErrBadToken
	}
	f.sent = append(f.sent, sent{token, m})
	return nil
}

func (f *fakeSender) take() []sent {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := f.sent
	f.sent = nil
	return out
}

func TestNotifications(t *testing.T) {
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL не задан — пропускаю тесты с базой")
	}
	ctx := context.Background()
	db, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := migrations.Apply(ctx, db); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(ctx, `TRUNCATE users CASCADE`); err != nil {
		t.Fatal(err)
	}
	user := func(phone, name string) string {
		var id string
		if err := db.QueryRow(ctx, `INSERT INTO users (phone_e164, birth_date, gender) VALUES ($1, '1995-01-01', 'female') RETURNING id`,
			phone).Scan(&id); err != nil {
			t.Fatal(err)
		}
		if _, err := db.Exec(ctx, `INSERT INTO profiles (user_id, display_name, city) VALUES ($1, $2, 'Чита')`, id, name); err != nil {
			t.Fatal(err)
		}
		return id
	}
	anna, igor := user("+79140002001", "Анна"), user("+79140002002", "Игорь")
	a, b := anna, igor
	if b < a {
		a, b = b, a
	}
	var match string
	if err := db.QueryRow(ctx, `INSERT INTO matches (user_a, user_b, goal) VALUES ($1, $2, 'hobby') RETURNING id`, a, b).Scan(&match); err != nil {
		t.Fatal(err)
	}

	fake := &fakeSender{bad: map[string]bool{"igor-old": true}}
	clock := time.Date(2026, 11, 16, 12, 0, 0, 0, time.UTC)
	s := &Service{DB: db, Sender: fake, Sync: true, Now: func() time.Time { return clock }}
	for _, tok := range []string{"igor-phone", "igor-old"} {
		if err := s.SetToken(ctx, igor, tok, "rustore"); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.SetToken(ctx, igor, "", ""); !errors.Is(err, ErrBadToken) {
		t.Fatal("пустой токен")
	}

	// Совпадение: Игорь узнаёт, Анна (сама нажала) — нет. Имени по умолчанию нет.
	s.Matched(ctx, match, anna)
	got := fake.take()
	if len(got) != 1 || got[0].token != "igor-phone" || got[0].m.Title != "Взаимный интерес" ||
		got[0].m.Body != "Можно начать разговор" || got[0].m.Data["match_id"] != match {
		t.Fatalf("совпадение: %+v", got)
	}
	var left int
	_ = db.QueryRow(ctx, `SELECT count(*) FROM push_tokens WHERE user_id = $1`, igor).Scan(&left)
	if left != 1 {
		t.Fatalf("недействительный токен должен удалиться, осталось %d", left)
	}

	// Сообщение: без имени и текста; второе подряд — без уведомления.
	s.MessageSent(ctx, match, anna, "Привет! Пойдём в субботу на эндуро?")
	s.MessageSent(ctx, match, anna, "И ещё вопрос")
	got = fake.take()
	if len(got) != 1 || got[0].m.Title != "Новое сообщение" || got[0].m.Body != "Откройте, чтобы прочитать" {
		t.Fatalf("сообщение: %+v", got)
	}

	// Включил подробности — видно имя и текст.
	if err := s.Set(ctx, igor, Settings{Matches: true, Messages: true, Nearby: true, ShowText: true}); err != nil {
		t.Fatal(err)
	}
	clock = clock.Add(MessageGap)
	s.MessageSent(ctx, match, anna, "Жду ответа")
	got = fake.take()
	if len(got) != 1 || got[0].m.Title != "Анна" || got[0].m.Body != "Жду ответа" {
		t.Fatalf("с текстом: %+v", got)
	}

	// Выключил сообщения и «рядом» — тишина.
	if err := s.Set(ctx, igor, Settings{Matches: true}); err != nil {
		t.Fatal(err)
	}
	clock = clock.Add(MessageGap)
	s.MessageSent(ctx, match, anna, "Ау")
	if err := s.Push(ctx, igor, "Рядом — свои люди", "текст"); err != nil {
		t.Fatal(err)
	}
	if got = fake.take(); len(got) != 0 {
		t.Fatalf("выключено, но пришло: %+v", got)
	}
	if st, _ := s.Get(ctx, igor); st.Messages || !st.Matches {
		t.Fatalf("настройки: %+v", st)
	}

	// Вышел из аккаунта — токен больше не его.
	if err := s.DeleteToken(ctx, igor, "igor-phone"); err != nil {
		t.Fatal(err)
	}
	s.Matched(ctx, match, anna)
	if got = fake.take(); len(got) != 0 {
		t.Fatalf("после выхода: %+v", got)
	}
	// Токен переезжает к новому аккаунту.
	if err := s.SetToken(ctx, anna, "igor-phone", ""); err != nil {
		t.Fatal(err)
	}
	s.Matched(ctx, match, igor)
	if got = fake.take(); len(got) != 1 || got[0].token != "igor-phone" {
		t.Fatalf("Анне на тот же телефон: %+v", got)
	}
}
