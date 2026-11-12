package auth

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/stepamolotok-star/interest-dating-app/backend/migrations"
)

func TestNormalizePhone(t *testing.T) {
	ok := map[string]string{
		"+7 914 123-45-67":  "+79141234567",
		"89141234567":       "+79141234567",
		"9141234567":        "+79141234567",
		"7 (914) 123 45 67": "+79141234567",
	}
	for in, want := range ok {
		if got, err := NormalizePhone(in); err != nil || got != want {
			t.Errorf("NormalizePhone(%q) = %q, %v", in, got, err)
		}
	}
	for _, bad := range []string{"", "+1 202 555 0100", "+7 495 123-45-67", "12345", "+380 50 123 4567"} {
		if _, err := NormalizePhone(bad); !errors.Is(err, ErrNotRussianMobile) {
			t.Errorf("NormalizePhone(%q) должен отклонить номер", bad)
		}
	}
}

func TestAge(t *testing.T) {
	now := time.Date(2026, 11, 12, 0, 0, 0, 0, time.UTC)
	cases := []struct {
		birth time.Time
		want  int
	}{
		{time.Date(2008, 11, 12, 0, 0, 0, 0, time.UTC), 18}, // день рождения сегодня
		{time.Date(2008, 11, 13, 0, 0, 0, 0, time.UTC), 17},
		{time.Date(1994, 3, 14, 0, 0, 0, 0, time.UTC), 32},
	}
	for _, c := range cases {
		if got := Age(c.birth, now); got != c.want {
			t.Errorf("Age(%s) = %d, ждали %d", c.birth.Format("2006-01-02"), got, c.want)
		}
	}
}

func TestRandomCode(t *testing.T) {
	for i := 0; i < 100; i++ {
		c, err := RandomCode(4)
		if err != nil || len(c) != 4 {
			t.Fatalf("RandomCode: %q %v", c, err)
		}
	}
}

// --- тесты с настоящей базой: нужна переменная TEST_DATABASE_URL ---

// fakeCaller «звонит» и запоминает код, как будто его увидел пользователь.
type fakeCaller struct{ last string }

func (f *fakeCaller) FlashCall(context.Context, string) (string, error) {
	f.last = "4821"
	return f.last, nil
}
func (f *fakeCaller) SendCode(_ context.Context, _, code string) error { f.last = code; return nil }

func newTestService(t *testing.T) (*Service, *fakeCaller, *time.Time) {
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
	if _, err := db.Exec(ctx, `TRUNCATE auth_attempts, sessions, users CASCADE`); err != nil {
		t.Fatal(err)
	}
	clock := time.Date(2026, 11, 12, 12, 0, 0, 0, time.UTC)
	fc := &fakeCaller{}
	s := &Service{DB: db, Caller: fc, SMS: fc, Secret: []byte("test-secret"), Now: func() time.Time { return clock }}
	return s, fc, &clock
}

func TestFlashCallLoginAndRegistration(t *testing.T) {
	s, fc, clock := newTestService(t)
	ctx := context.Background()

	ch, err := s.Start(ctx, "8 914 123-45-67", "")
	if err != nil || ch.Method != FlashCall || ch.CodeLength != 4 {
		t.Fatalf("Start: %+v %v", ch, err)
	}
	sess, err := s.Verify(ctx, "+79141234567", fc.last)
	if err != nil || sess.Registered || sess.Token == "" {
		t.Fatalf("Verify: %+v %v", sess, err)
	}
	if _, err := s.Verify(ctx, "+79141234567", fc.last); !errors.Is(err, ErrNoActiveCode) {
		t.Fatalf("код одноразовый, получили %v", err)
	}

	reg := Registration{Name: "Игорь", BirthDate: time.Date(1994, 3, 14, 0, 0, 0, 0, time.UTC),
		Gender: "male", City: "Чита", Terms: true, PersonalData: true, DocVersion: "2026-11"}

	under := reg
	under.BirthDate = clock.AddDate(-17, 0, 0)
	if _, err := s.Register(ctx, sess.Token, under); !errors.Is(err, ErrUnderage) {
		t.Fatalf("младше 18: %v", err)
	}
	noConsent := reg
	noConsent.PersonalData = false
	if _, err := s.Register(ctx, sess.Token, noConsent); !errors.Is(err, ErrConsentsRequired) {
		t.Fatalf("без согласия: %v", err)
	}

	userID, err := s.Register(ctx, sess.Token, reg)
	if err != nil || userID == "" {
		t.Fatalf("Register: %v", err)
	}
	id, err := s.Authenticate(ctx, sess.Token)
	if err != nil || id.UserID != userID || id.Phone != "+79141234567" {
		t.Fatalf("Authenticate: %+v %v", id, err)
	}
	if _, err := s.Register(ctx, sess.Token, reg); !errors.Is(err, ErrAlreadyRegistered) {
		t.Fatalf("повторная регистрация: %v", err)
	}
	var consents int
	if err := s.DB.QueryRow(ctx, `SELECT count(*) FROM consents WHERE user_id = $1`, userID).Scan(&consents); err != nil || consents != 2 {
		t.Fatalf("согласия должны быть записаны отдельно: %d %v", consents, err)
	}

	// Повторный вход того же человека — сразу зарегистрирован.
	*clock = clock.Add(2 * time.Minute)
	if _, err := s.Start(ctx, "9141234567", SMS); err != nil {
		t.Fatal(err)
	}
	sess2, err := s.Verify(ctx, "9141234567", fc.last)
	if err != nil || !sess2.Registered {
		t.Fatalf("повторный вход: %+v %v", sess2, err)
	}
	if err := s.Logout(ctx, sess2.Token); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Authenticate(ctx, sess2.Token); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("после выхода токен недействителен: %v", err)
	}
}

func TestLimits(t *testing.T) {
	s, _, clock := newTestService(t)
	ctx := context.Background()
	phone := "+79990001122"

	if _, err := s.Start(ctx, phone, ""); err != nil {
		t.Fatal(err)
	}
	var re *RetryError
	if _, err := s.Start(ctx, phone, ""); !errors.As(err, &re) || !errors.Is(err, ErrRetryLater) || re.After <= 0 {
		t.Fatalf("повтор раньше минуты: %v", err)
	}

	// Три неверных кода подряд — код сгорает.
	for i := 1; i <= MaxVerifyAttempts; i++ {
		_, err := s.Verify(ctx, phone, "0000")
		want := ErrWrongCode
		if i == MaxVerifyAttempts {
			want = ErrTooManyAttempts
		}
		if !errors.Is(err, want) {
			t.Fatalf("попытка %d: %v", i, err)
		}
	}
	if _, err := s.Verify(ctx, phone, "4821"); !errors.Is(err, ErrNoActiveCode) {
		t.Fatalf("после трёх ошибок даже верный код не принимается: %v", err)
	}

	// Не больше пяти кодов в час.
	for i := 0; i < MaxCodesPerHour-1; i++ {
		*clock = clock.Add(ResendAfter + time.Second)
		if _, err := s.Start(ctx, phone, ""); err != nil {
			t.Fatalf("код %d: %v", i+2, err)
		}
	}
	*clock = clock.Add(ResendAfter + time.Second)
	if _, err := s.Start(ctx, phone, ""); !errors.Is(err, ErrTooManyCodes) {
		t.Fatalf("шестой код за час: %v", err)
	}
}

func TestExpiredCode(t *testing.T) {
	s, fc, clock := newTestService(t)
	ctx := context.Background()
	if _, err := s.Start(ctx, "+79141112233", ""); err != nil {
		t.Fatal(err)
	}
	*clock = clock.Add(CodeTTL + time.Second)
	if _, err := s.Verify(ctx, "+79141112233", fc.last); !errors.Is(err, ErrNoActiveCode) {
		t.Fatalf("просроченный код: %v", err)
	}
}
