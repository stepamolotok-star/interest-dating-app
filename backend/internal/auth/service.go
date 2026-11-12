// Package auth — вход по номеру телефона и регистрация.
//
// Поток: Start (звонок-сброс или SMS) → Verify (проверка кода, выдача
// сессии) → Register (для новых: имя, дата рождения, согласия).
package auth

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/contacts"
)

// Параметры входа.
const (
	CodeLength        = 4
	CodeTTL           = 5 * time.Minute
	ResendAfter       = 60 * time.Second
	MaxCodesPerHour   = 5
	MaxVerifyAttempts = 3
	SessionTTL        = 30 * 24 * time.Hour
)

// Method — способ доставки кода.
type Method string

const (
	FlashCall Method = "flash_call"
	SMS       Method = "sms"
)

// Ошибки, которые API превращает в понятные пользователю ответы.
var (
	ErrRetryLater        = errors.New("запросить код снова можно чуть позже")
	ErrTooManyCodes      = errors.New("слишком много запросов кода, попробуйте через час")
	ErrNoActiveCode      = errors.New("код истёк или не запрашивался, запросите новый")
	ErrWrongCode         = errors.New("неверный код")
	ErrTooManyAttempts   = errors.New("слишком много неверных попыток, запросите новый код")
	ErrUnauthorized      = errors.New("нужно войти заново")
	ErrAlreadyRegistered = errors.New("регистрация уже пройдена")
	ErrUnderage          = errors.New("приложение доступно только с 18 лет")
	ErrConsentsRequired  = errors.New("нужны согласие с соглашением и на обработку персональных данных")
)

// RetryError сообщает, через сколько можно повторить запрос.
type RetryError struct {
	Err   error
	After time.Duration
}

func (e *RetryError) Error() string { return e.Err.Error() }
func (e *RetryError) Unwrap() error { return e.Err }

// ValidationError — ошибка в данных регистрации.
type ValidationError struct{ Field, Message string }

func (e *ValidationError) Error() string { return e.Field + ": " + e.Message }

// Service — логика входа. Secret — ключ HMAC для кодов, из конфигурации.
type Service struct {
	DB     *pgxpool.Pool
	Caller Caller
	SMS    SMSSender
	Secret []byte
	// ContactsSecret — секрет для ключа номера («скрыть от контактов»); пустой — берётся Secret.
	ContactsSecret []byte
	Now            func() time.Time
}

func (s *Service) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// Challenge — что показать на экране ввода кода.
type Challenge struct {
	Method      Method        `json:"method"`
	CodeLength  int           `json:"code_length"`
	ExpiresIn   time.Duration `json:"-"`
	ResendAfter time.Duration `json:"-"`
}

// Start запрашивает код. По умолчанию — звонок-сброс; SMS — если пользователь
// нажал «Звонок не пришёл».
func (s *Service) Start(ctx context.Context, rawPhone string, method Method) (Challenge, error) {
	phone, err := NormalizePhone(rawPhone)
	if err != nil {
		return Challenge{}, err
	}
	if method == "" {
		method = FlashCall
	}
	if method != FlashCall && method != SMS {
		return Challenge{}, &ValidationError{"method", "неизвестный способ"}
	}
	now := s.now()

	var count int
	var last *time.Time
	err = s.DB.QueryRow(ctx, `
		SELECT count(*), max(created_at) FROM auth_attempts
		WHERE phone_e164 = $1 AND created_at > $2`, phone, now.Add(-time.Hour)).Scan(&count, &last)
	if err != nil {
		return Challenge{}, err
	}
	if last != nil && now.Sub(*last) < ResendAfter {
		return Challenge{}, &RetryError{ErrRetryLater, ResendAfter - now.Sub(*last)}
	}
	if count >= MaxCodesPerHour {
		return Challenge{}, &RetryError{ErrTooManyCodes, time.Hour - now.Sub(*last)}
	}

	var code string
	switch method {
	case FlashCall:
		code, err = s.Caller.FlashCall(ctx, phone)
	case SMS:
		if code, err = RandomCode(CodeLength); err == nil {
			err = s.SMS.SendCode(ctx, phone, code)
		}
	}
	if err != nil {
		return Challenge{}, fmt.Errorf("auth: доставка кода: %w", err)
	}

	_, err = s.DB.Exec(ctx, `
		INSERT INTO auth_attempts (phone_e164, method, code_hash, created_at, expires_at)
		VALUES ($1, $2, $3, $4, $5)`, phone, method, s.codeHash(phone, code), now, now.Add(CodeTTL))
	if err != nil {
		return Challenge{}, err
	}
	return Challenge{Method: method, CodeLength: len(code), ExpiresIn: CodeTTL, ResendAfter: ResendAfter}, nil
}

// Session — результат успешного входа.
type Session struct {
	Token      string
	Registered bool // false — нужно пройти регистрацию
}

// Verify проверяет код и выдаёт сессию.
func (s *Service) Verify(ctx context.Context, rawPhone, code string) (Session, error) {
	phone, err := NormalizePhone(rawPhone)
	if err != nil {
		return Session{}, err
	}
	code = strings.TrimSpace(code)
	now := s.now()

	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return Session{}, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck // после Commit — no-op

	var id string
	var hash []byte
	var attempts int
	err = tx.QueryRow(ctx, `
		SELECT id, code_hash, attempts FROM auth_attempts
		WHERE phone_e164 = $1 AND consumed_at IS NULL AND expires_at > $2
		ORDER BY created_at DESC LIMIT 1
		FOR UPDATE`, phone, now).Scan(&id, &hash, &attempts)
	if errors.Is(err, pgx.ErrNoRows) {
		return Session{}, ErrNoActiveCode
	}
	if err != nil {
		return Session{}, err
	}
	if attempts >= MaxVerifyAttempts {
		return Session{}, ErrTooManyAttempts
	}
	if !hmac.Equal(hash, s.codeHash(phone, code)) {
		attempts++
		q := `UPDATE auth_attempts SET attempts = $2 WHERE id = $1`
		if attempts >= MaxVerifyAttempts {
			q = `UPDATE auth_attempts SET attempts = $2, consumed_at = now() WHERE id = $1`
		}
		if _, err := tx.Exec(ctx, q, id, attempts); err != nil {
			return Session{}, err
		}
		if err := tx.Commit(ctx); err != nil {
			return Session{}, err
		}
		if attempts >= MaxVerifyAttempts {
			return Session{}, ErrTooManyAttempts
		}
		return Session{}, ErrWrongCode
	}
	if _, err := tx.Exec(ctx, `UPDATE auth_attempts SET consumed_at = $2 WHERE id = $1`, id, now); err != nil {
		return Session{}, err
	}

	var userID *string
	err = tx.QueryRow(ctx, `SELECT id FROM users WHERE phone_e164 = $1 AND deleted_at IS NULL`, phone).Scan(&userID)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return Session{}, err
	}
	token, err := newToken()
	if err != nil {
		return Session{}, err
	}
	_, err = tx.Exec(ctx, `
		INSERT INTO sessions (token_hash, phone_e164, user_id, created_at, expires_at)
		VALUES ($1, $2, $3, $4, $5)`, tokenHash(token), phone, userID, now, now.Add(SessionTTL))
	if err != nil {
		return Session{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Session{}, err
	}
	return Session{Token: token, Registered: userID != nil}, nil
}

// Identity — кто стоит за токеном.
type Identity struct {
	Phone  string
	UserID string // пусто, пока регистрация не пройдена
}

// Authenticate проверяет токен сессии.
func (s *Service) Authenticate(ctx context.Context, token string) (Identity, error) {
	if token == "" {
		return Identity{}, ErrUnauthorized
	}
	var id Identity
	var userID *string
	err := s.DB.QueryRow(ctx, `
		SELECT phone_e164, user_id FROM sessions
		WHERE token_hash = $1 AND revoked_at IS NULL AND expires_at > $2`,
		tokenHash(token), s.now()).Scan(&id.Phone, &userID)
	if errors.Is(err, pgx.ErrNoRows) {
		return Identity{}, ErrUnauthorized
	}
	if err != nil {
		return Identity{}, err
	}
	if userID != nil {
		id.UserID = *userID
	}
	return id, nil
}

// Logout отзывает сессию.
func (s *Service) Logout(ctx context.Context, token string) error {
	_, err := s.DB.Exec(ctx, `UPDATE sessions SET revoked_at = now() WHERE token_hash = $1`, tokenHash(token))
	return err
}

// Registration — данные шага «Расскажите о себе».
type Registration struct {
	Name         string
	BirthDate    time.Time
	Gender       string // male | female
	City         string
	Terms        bool // принял пользовательское соглашение
	PersonalData bool // согласие на обработку ПДн — отдельный документ
	DocVersion   string
}

// Register создаёт пользователя для сессии, которая ещё не привязана к аккаунту.
func (s *Service) Register(ctx context.Context, token string, r Registration) (string, error) {
	if err := s.validate(r); err != nil {
		return "", err
	}
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return "", err
	}
	defer tx.Rollback(ctx) //nolint:errcheck

	var sessionID, phone string
	var existing *string
	err = tx.QueryRow(ctx, `
		SELECT id, phone_e164, user_id FROM sessions
		WHERE token_hash = $1 AND revoked_at IS NULL AND expires_at > $2
		FOR UPDATE`, tokenHash(token), s.now()).Scan(&sessionID, &phone, &existing)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrUnauthorized
	}
	if err != nil {
		return "", err
	}
	if existing != nil {
		return "", ErrAlreadyRegistered
	}

	var userID string
	err = tx.QueryRow(ctx, `
		INSERT INTO users (phone_e164, birth_date, gender, phone_key) VALUES ($1, $2, $3, $4)
		ON CONFLICT (phone_e164) DO NOTHING
		RETURNING id`, phone, r.BirthDate, r.Gender, contacts.PhoneKey(s.contactsSecret(), phone)).Scan(&userID)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrAlreadyRegistered
	}
	if err != nil {
		return "", err
	}
	stmts := []struct {
		sql  string
		args []any
	}{
		{`INSERT INTO profiles (user_id, display_name, city) VALUES ($1, $2, $3)`, []any{userID, strings.TrimSpace(r.Name), strings.TrimSpace(r.City)}},
		{`INSERT INTO consents (user_id, kind, doc_version) VALUES ($1, 'terms', $2), ($1, 'personal_data', $2)`, []any{userID, r.DocVersion}},
		{`INSERT INTO visibility_settings (user_id) VALUES ($1)`, []any{userID}},
		{`UPDATE sessions SET user_id = $1 WHERE phone_e164 = $2 AND user_id IS NULL`, []any{userID, phone}},
	}
	for _, st := range stmts {
		if _, err := tx.Exec(ctx, st.sql, st.args...); err != nil {
			return "", err
		}
	}
	return userID, tx.Commit(ctx)
}

func (s *Service) validate(r Registration) error {
	if !r.Terms || !r.PersonalData {
		return ErrConsentsRequired
	}
	if r.DocVersion == "" {
		return &ValidationError{"doc_version", "не указана версия документов"}
	}
	name := strings.TrimSpace(r.Name)
	if n := utf8.RuneCountInString(name); n < 2 || n > 40 {
		return &ValidationError{"name", "имя должно быть от 2 до 40 символов"}
	}
	if utf8.RuneCountInString(strings.TrimSpace(r.City)) < 2 {
		return &ValidationError{"city", "укажите город"}
	}
	if r.Gender != "male" && r.Gender != "female" {
		return &ValidationError{"gender", "укажите пол"}
	}
	if Age(r.BirthDate, s.now()) < 18 {
		return ErrUnderage
	}
	if Age(r.BirthDate, s.now()) > 100 {
		return &ValidationError{"birth_date", "проверьте дату рождения"}
	}
	return nil
}

// Age — полных лет на дату now.
func Age(birth, now time.Time) int {
	years := now.Year() - birth.Year()
	if now.Month() < birth.Month() || (now.Month() == birth.Month() && now.Day() < birth.Day()) {
		years--
	}
	return years
}

// contactsSecret — ключ для phone_key; должен совпадать с contacts.Service.Secret.
func (s *Service) contactsSecret() []byte {
	if len(s.ContactsSecret) > 0 {
		return s.ContactsSecret
	}
	return s.Secret
}

func (s *Service) codeHash(phone, code string) []byte {
	m := hmac.New(sha256.New, s.Secret)
	m.Write([]byte(phone + ":" + code))
	return m.Sum(nil)
}

func newToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

func tokenHash(token string) []byte {
	h := sha256.Sum256([]byte(token))
	return h[:]
}

// Me — краткие данные своего аккаунта.
type Me struct {
	UserID        string `json:"user_id"`
	Name          string `json:"name"`
	City          string `json:"city"`
	Age           int    `json:"age"`
	PhotoVerified bool   `json:"photo_verified"`
	AgeVerified   bool   `json:"age_verified"`
}

// Me возвращает данные аккаунта по userID.
func (s *Service) Me(ctx context.Context, userID string) (Me, error) {
	m := Me{UserID: userID}
	var birth time.Time
	var photo, gos *time.Time
	err := s.DB.QueryRow(ctx, `
		SELECT p.display_name, p.city, u.birth_date, u.photo_verified_at, u.gosuslugi_verified_at
		FROM users u JOIN profiles p ON p.user_id = u.id
		WHERE u.id = $1 AND u.deleted_at IS NULL`, userID).Scan(&m.Name, &m.City, &birth, &photo, &gos)
	if errors.Is(err, pgx.ErrNoRows) {
		return Me{}, ErrUnauthorized
	}
	if err != nil {
		return Me{}, err
	}
	m.Age = Age(birth, s.now())
	m.PhotoVerified, m.AgeVerified = photo != nil, gos != nil
	return m, nil
}
