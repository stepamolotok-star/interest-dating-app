// Package oauth — вход через российские ID-сервисы (VK ID, Яндекс ID).
//
// От провайдера берём только подтверждённый номер телефона: он и есть наш логин,
// как при входе по звонку. Имя, фото, друзей и прочее не запрашиваем и не храним;
// токены провайдера выбрасываем сразу после получения номера.
//
// Поток (OAuth 2.1 + PKCE, обмен кода на сервере):
//  1. приложение вызывает Start — сервер создаёт state и code_verifier и возвращает ссылку;
//  2. приложение открывает ссылку в браузере, человек входит у провайдера;
//  3. провайдер возвращает приложение по redirect_uri с code и state;
//  4. приложение вызывает Finish — сервер меняет code на токен, получает номер.
package oauth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// StateTTL — сколько живёт незавершённый вход.
const StateTTL = 10 * time.Minute

// Ошибки для пользователя.
var (
	ErrUnknownProvider = errors.New("такой способ входа не подключён")
	ErrExpired         = errors.New("вход занял слишком много времени — попробуйте ещё раз")
	ErrNoPhone         = errors.New("в аккаунте нет подтверждённого номера телефона — войдите по звонку")
	ErrDenied          = errors.New("не удалось подтвердить вход — попробуйте ещё раз или войдите по звонку")
)

// Provider — один ID-сервис.
type Provider interface {
	ID() string
	Name() string
	// RedirectURI — куда провайдер вернёт приложение; схема нужна приложению,
	// чтобы перехватить возврат.
	RedirectURI() string
	AuthorizeURL(state, codeChallenge string) string
	// Phone меняет код на токен и возвращает номер телефона из аккаунта.
	Phone(ctx context.Context, code, codeVerifier, deviceID, state string) (string, error)
}

// Service хранит незавершённые входы.
type Service struct {
	DB        *pgxpool.Pool
	Providers []Provider
	Now       func() time.Time
}

func (s *Service) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// Info — способ входа для экрана входа.
type Info struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// List — подключённые способы входа.
func (s *Service) List() []Info {
	out := make([]Info, 0, len(s.Providers))
	for _, p := range s.Providers {
		out = append(out, Info{ID: p.ID(), Name: p.Name()})
	}
	return out
}

func (s *Service) provider(id string) (Provider, error) {
	for _, p := range s.Providers {
		if p.ID() == id {
			return p, nil
		}
	}
	return nil, ErrUnknownProvider
}

// Started — ссылка для браузера и куда ждать возврата.
type Started struct {
	URL         string `json:"url"`
	State       string `json:"state"`
	RedirectURI string `json:"redirect_uri"`
}

// Start создаёт попытку входа.
func (s *Service) Start(ctx context.Context, providerID string) (Started, error) {
	p, err := s.provider(providerID)
	if err != nil {
		return Started{}, err
	}
	state, verifier := randomString(32), randomString(48)
	// Заодно подчищаем брошенные попытки.
	if _, err := s.DB.Exec(ctx, `DELETE FROM oauth_states WHERE created_at < $1`, s.now().Add(-StateTTL)); err != nil {
		return Started{}, err
	}
	if _, err := s.DB.Exec(ctx, `INSERT INTO oauth_states (state, provider, code_verifier, created_at) VALUES ($1, $2, $3, $4)`,
		state, p.ID(), verifier, s.now()); err != nil {
		return Started{}, err
	}
	return Started{URL: p.AuthorizeURL(state, Challenge(verifier)), State: state, RedirectURI: p.RedirectURI()}, nil
}

// Finish завершает вход и возвращает номер телефона. Попытка одноразовая.
func (s *Service) Finish(ctx context.Context, providerID, state, code, deviceID string) (string, error) {
	p, err := s.provider(providerID)
	if err != nil {
		return "", err
	}
	var verifier string
	var created time.Time
	err = s.DB.QueryRow(ctx, `DELETE FROM oauth_states WHERE state = $1 AND provider = $2 RETURNING code_verifier, created_at`,
		state, p.ID()).Scan(&verifier, &created)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && s.now().Sub(created) > StateTTL) {
		return "", ErrExpired
	}
	if err != nil {
		return "", err
	}
	if code == "" {
		return "", ErrDenied
	}
	return p.Phone(ctx, code, verifier, deviceID, state)
}

// Challenge — code_challenge по методу S256 (RFC 7636).
func Challenge(verifier string) string {
	h := sha256.Sum256([]byte(verifier))
	return base64.RawURLEncoding.EncodeToString(h[:])
}

// randomString — n случайных байт в base64url: только a-z, A-Z, 0-9, «-» и «_», как требует VK ID.
func randomString(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

// httpClient с таймаутом для запросов к провайдерам.
var httpClient = &http.Client{Timeout: 10 * time.Second}
