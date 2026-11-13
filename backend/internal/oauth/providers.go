package oauth

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
)

// VKID — вход через VK ID (id.vk.ru). Запрашиваем только право phone.
type VKID struct {
	ClientID string
	// Redirect — адрес возврата, как в настройках приложения VK ID.
	// Для мобильного приложения обычно vk<ClientID>://vk.ru/blank.html.
	Redirect string
	// BaseURL — для тестов; пусто — https://id.vk.ru.
	BaseURL string
}

func (v VKID) base() string {
	if v.BaseURL != "" {
		return v.BaseURL
	}
	return "https://id.vk.ru"
}

func (VKID) ID() string            { return "vk" }
func (VKID) Name() string          { return "VK ID" }
func (v VKID) RedirectURI() string { return v.Redirect }

func (v VKID) AuthorizeURL(state, challenge string) string {
	q := url.Values{
		"response_type":         {"code"},
		"client_id":             {v.ClientID},
		"redirect_uri":          {v.Redirect},
		"scope":                 {"phone"},
		"state":                 {state},
		"code_challenge":        {challenge},
		"code_challenge_method": {"S256"},
	}
	return v.base() + "/authorize?" + q.Encode()
}

func (v VKID) Phone(ctx context.Context, code, verifier, deviceID, state string) (string, error) {
	var tok struct {
		AccessToken string `json:"access_token"`
		Error       string `json:"error"`
	}
	if err := postForm(ctx, v.base()+"/oauth2/auth", url.Values{
		"grant_type":    {"authorization_code"},
		"code":          {code},
		"code_verifier": {verifier},
		"client_id":     {v.ClientID},
		"device_id":     {deviceID},
		"redirect_uri":  {v.Redirect},
		"state":         {state},
	}, "", &tok); err != nil {
		return "", err
	}
	if tok.AccessToken == "" {
		return "", ErrDenied
	}
	var info struct {
		User struct {
			Phone string `json:"phone"`
		} `json:"user"`
	}
	if err := postForm(ctx, v.base()+"/oauth2/user_info?client_id="+url.QueryEscape(v.ClientID),
		url.Values{"access_token": {tok.AccessToken}}, "", &info); err != nil {
		return "", err
	}
	if info.User.Phone == "" {
		return "", ErrNoPhone
	}
	return info.User.Phone, nil
}

// YandexID — вход через Яндекс ID. Запрашиваем только login:default_phone.
type YandexID struct {
	ClientID string
	Redirect string
	// OAuthURL и LoginURL — для тестов; пусто — oauth.yandex.ru и login.yandex.ru.
	OAuthURL string
	LoginURL string
}

func (y YandexID) oauthBase() string {
	if y.OAuthURL != "" {
		return y.OAuthURL
	}
	return "https://oauth.yandex.ru"
}

func (y YandexID) loginBase() string {
	if y.LoginURL != "" {
		return y.LoginURL
	}
	return "https://login.yandex.ru"
}

func (YandexID) ID() string            { return "yandex" }
func (YandexID) Name() string          { return "Яндекс ID" }
func (y YandexID) RedirectURI() string { return y.Redirect }

func (y YandexID) AuthorizeURL(state, challenge string) string {
	q := url.Values{
		"response_type":         {"code"},
		"client_id":             {y.ClientID},
		"redirect_uri":          {y.Redirect},
		"scope":                 {"login:default_phone"},
		"state":                 {state},
		"code_challenge":        {challenge},
		"code_challenge_method": {"S256"},
		"force_confirm":         {"yes"},
	}
	return y.oauthBase() + "/authorize?" + q.Encode()
}

func (y YandexID) Phone(ctx context.Context, code, verifier, _, _ string) (string, error) {
	var tok struct {
		AccessToken string `json:"access_token"`
	}
	if err := postForm(ctx, y.oauthBase()+"/token", url.Values{
		"grant_type":    {"authorization_code"},
		"code":          {code},
		"client_id":     {y.ClientID},
		"code_verifier": {verifier},
	}, "", &tok); err != nil {
		return "", err
	}
	if tok.AccessToken == "" {
		return "", ErrDenied
	}
	var info struct {
		DefaultPhone *struct {
			Number string `json:"number"`
		} `json:"default_phone"`
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, y.loginBase()+"/info?format=json", nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "OAuth "+tok.AccessToken)
	if err := do(req, &info); err != nil {
		return "", err
	}
	if info.DefaultPhone == nil || info.DefaultPhone.Number == "" {
		return "", ErrNoPhone
	}
	return info.DefaultPhone.Number, nil
}

func postForm(ctx context.Context, u string, form url.Values, auth string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u, strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	if auth != "" {
		req.Header.Set("Authorization", auth)
	}
	return do(req, out)
}

// do выполняет запрос. Ошибку провайдера (4xx) считаем отказом во входе,
// а сетевые сбои и 5xx — внутренней ошибкой.
func do(req *http.Request, out any) error {
	res, err := httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("oauth: %s: %w", req.URL.Host, err)
	}
	defer res.Body.Close()
	body, err := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if err != nil {
		return err
	}
	if res.StatusCode >= 400 && res.StatusCode < 500 {
		return ErrDenied
	}
	if res.StatusCode >= 500 {
		return fmt.Errorf("oauth: %s ответил %d", req.URL.Host, res.StatusCode)
	}
	if err := json.Unmarshal(body, out); err != nil {
		return fmt.Errorf("oauth: %s: непонятный ответ: %w", req.URL.Host, err)
	}
	return nil
}
