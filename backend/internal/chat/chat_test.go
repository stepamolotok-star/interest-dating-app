package chat

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/catalog"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/profile"
	"github.com/stepamolotok-star/interest-dating-app/backend/migrations"
)

func TestHasContacts(t *testing.T) {
	yes := []string{
		"Пиши в телегу", "мой ник @anna_moto", "звони +7 914 123-45-67", "89141234567",
		"vk.com/id1", "https://example.com", "t.me/anna", "лучше в ватсап", "заходи на moto-club.ru",
	}
	no := []string{
		"Привет! Какое дерево было первым?", "Катаюсь с 2015 года, 3 сезона на эндуро",
		"Встретимся в субботу в 10:00?", "Мне 29, тебе?",
	}
	for _, s := range yes {
		if !HasContacts(s) {
			t.Errorf("должно найти контакт: %q", s)
		}
	}
	for _, s := range no {
		if HasContacts(s) {
			t.Errorf("ложное срабатывание: %q", s)
		}
	}
}

type env struct {
	db   *pgxpool.Pool
	chat *Service
	prof *profile.Service
	n    int
}

func setup(t *testing.T) *env {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL не задан — пропускаю тесты с базой")
	}
	ctx := context.Background()
	db, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	if _, err := migrations.Apply(ctx, db); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(ctx, `TRUNCATE users CASCADE`); err != nil {
		t.Fatal(err)
	}
	cat, _ := catalog.Default()
	prof := &profile.Service{DB: db, Catalog: cat}
	if err := prof.SyncCatalog(ctx); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 11, 12, 12, 0, 0, 0, time.UTC)
	return &env{db: db, prof: prof, chat: &Service{DB: db, Catalog: cat, Now: func() time.Time { return now }}}
}

func (e *env) user(t *testing.T, name string) string {
	t.Helper()
	e.n++
	var id string
	err := e.db.QueryRow(context.Background(), `INSERT INTO users (phone_e164, birth_date, gender)
		VALUES ($1, '1996-05-20', 'female') RETURNING id`, fmt.Sprintf("+7914%07d", e.n)).Scan(&id)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.db.Exec(context.Background(), `INSERT INTO profiles (user_id, display_name, city, about)
		VALUES ($1, $2, 'Чита', 'Обо мне')`, id, name); err != nil {
		t.Fatal(err)
	}
	return id
}

func (e *env) match(t *testing.T, a, b string) string {
	t.Helper()
	if a > b {
		a, b = b, a
	}
	var id string
	if err := e.db.QueryRow(context.Background(), `INSERT INTO matches (user_a, user_b, goal) VALUES ($1, $2, 'hobby') RETURNING id`,
		a, b).Scan(&id); err != nil {
		t.Fatal(err)
	}
	return id
}

func TestChatFlow(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	anna, igor, stranger := e.user(t, "Анна"), e.user(t, "Игорь"), e.user(t, "Чужой")
	if err := e.prof.SetInterests(ctx, anna, []profile.Interest{{ID: "home.garden.bonsai", Level: "doing"}}); err != nil {
		t.Fatal(err)
	}
	if err := e.prof.SetVisibility(ctx, anna, map[string]string{"about": profile.Hidden}); err != nil {
		t.Fatal(err)
	}
	m := e.match(t, anna, igor)

	list, err := e.chat.Matches(ctx, igor)
	if err != nil || len(list) != 1 {
		t.Fatalf("Matches: %v %v", list, err)
	}
	other := list[0].Other
	if other.Name != "Анна" || other.Age != 30 || other.About != "" || len(other.Interests) != 1 || other.Interests[0] != "Бонсай" {
		t.Fatalf("раскрытый профиль: %+v («о себе» скрыто — его не должно быть)", other)
	}

	if _, err := e.chat.Send(ctx, igor, m, "Привет! Пиши в телегу @igor_moto"); !errors.Is(err, ErrContactsInHello) {
		t.Fatalf("контакты в первом сообщении: %v", err)
	}
	if _, err := e.chat.Send(ctx, igor, m, "   "); !errors.Is(err, ErrEmpty) {
		t.Fatalf("пустое: %v", err)
	}
	if _, err := e.chat.Send(ctx, igor, m, strings.Repeat("а", MaxMessageLen+1)); !errors.Is(err, ErrTooLong) {
		t.Fatalf("длинное: %v", err)
	}
	if _, err := e.chat.Send(ctx, igor, m, "Вы оба занимаетесь бонсаем. Какое дерево было первым?"); err != nil {
		t.Fatal(err)
	}
	if _, err := e.chat.Send(ctx, anna, m, "Можжевельник! Вот мой канал t.me/anna_bonsai"); err != nil {
		t.Fatalf("после знакомства ссылки можно: %v", err)
	}
	if _, err := e.chat.Send(ctx, stranger, m, "Привет"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("чужой не пишет в чужую переписку: %v", err)
	}
	if _, err := e.chat.Messages(ctx, stranger, m, 0); !errors.Is(err, ErrNotFound) {
		t.Fatalf("чужой не читает: %v", err)
	}
	msgs, err := e.chat.Messages(ctx, anna, m, 0)
	if err != nil || len(msgs) != 2 || msgs[0].Sender != anna {
		t.Fatalf("Messages: %+v %v", msgs, err)
	}
	if older, _ := e.chat.Messages(ctx, anna, m, msgs[0].ID); len(older) != 1 {
		t.Fatalf("листание назад: %v", older)
	}
	if list, _ := e.chat.Matches(ctx, anna); list[0].LastMessage == nil || !strings.HasPrefix(list[0].LastMessage.Body, "Можжевельник") {
		t.Fatalf("последнее сообщение в списке: %+v", list[0].LastMessage)
	}

	if err := e.chat.End(ctx, anna, m); err != nil {
		t.Fatal(err)
	}
	if _, err := e.chat.Messages(ctx, igor, m, 0); !errors.Is(err, ErrNotFound) {
		t.Fatalf("после разрыва переписка закрыта для обоих: %v", err)
	}
	if list, _ := e.chat.Matches(ctx, igor); len(list) != 0 {
		t.Fatalf("после разрыва совпадения нет: %v", list)
	}
	if _, err := e.chat.Messages(ctx, anna, "не-uuid", 0); !errors.Is(err, ErrNotFound) {
		t.Fatalf("кривой идентификатор: %v", err)
	}
}

func TestBlockAndReport(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	anna, igor := e.user(t, "Анна"), e.user(t, "Игорь")
	m := e.match(t, anna, igor)

	if err := e.chat.Block(ctx, anna, igor); err != nil {
		t.Fatal(err)
	}
	if _, err := e.chat.Send(ctx, igor, m, "Почему?"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("после блокировки переписка закрыта: %v", err)
	}
	if err := e.chat.Block(ctx, anna, igor); err != nil {
		t.Fatalf("повторная блокировка не ошибка: %v", err)
	}
	if err := e.chat.Block(ctx, anna, "00000000-0000-0000-0000-000000000000"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("блокировка несуществующего: %v", err)
	}

	urgent, err := e.chat.Report(ctx, anna, igor, "stalking", "Пишет с разных аккаунтов")
	if err != nil || !urgent {
		t.Fatalf("преследование — срочная жалоба: %v %v", urgent, err)
	}
	if urgent, err = e.chat.Report(ctx, anna, igor, "spam", ""); err != nil || urgent {
		t.Fatalf("спам — обычная: %v %v", urgent, err)
	}
	if _, err := e.chat.Report(ctx, anna, igor, "не нравится", ""); !errors.Is(err, ErrBadReason) {
		t.Fatalf("неизвестная причина: %v", err)
	}
	if _, err := e.chat.Report(ctx, anna, anna, "spam", ""); !errors.Is(err, ErrNotFound) {
		t.Fatalf("на себя: %v", err)
	}
}
