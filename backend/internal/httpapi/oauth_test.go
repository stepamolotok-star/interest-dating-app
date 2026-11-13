package httpapi

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/auth"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/catalog"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/oauth"
	"github.com/stepamolotok-star/interest-dating-app/backend/migrations"
)

// fakeProvider изображает VK ID и Яндекс ID: проверяет PKCE и отдаёт номер.
type fakeProvider struct {
	challenges map[string]string // code → code_challenge из ссылки авторизации
	phone      string
}

func (f *fakeProvider) handler(t *testing.T) http.Handler {
	mux := http.NewServeMux()
	token := func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		if r.Form.Get("grant_type") != "authorization_code" ||
			oauth.Challenge(r.Form.Get("code_verifier")) != f.challenges[r.Form.Get("code")] {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = io.WriteString(w, `{"error":"invalid_grant"}`)
			return
		}
		_, _ = io.WriteString(w, `{"access_token":"at-`+r.Form.Get("code")+`"}`)
	}
	mux.HandleFunc("POST /oauth2/auth", func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		if r.Form.Get("device_id") == "" {
			t.Error("VK ID требует device_id")
		}
		token(w, r)
	})
	mux.HandleFunc("POST /token", token)
	mux.HandleFunc("POST /oauth2/user_info", func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"user": map[string]any{"phone": f.phone, "first_name": "Иван"}})
	})
	mux.HandleFunc("GET /info", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") == "" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		body := map[string]any{"id": "1"}
		if f.phone != "" {
			body["default_phone"] = map[string]any{"id": 1, "number": f.phone}
		}
		_ = json.NewEncoder(w).Encode(body)
	})
	return mux
}

func oauthServer(t *testing.T, fake *fakeProvider) *httptest.Server {
	t.Helper()
	dbURL := os.Getenv("TEST_DATABASE_URL")
	if dbURL == "" {
		t.Skip("TEST_DATABASE_URL не задан — пропускаю тесты с базой")
	}
	ctx := context.Background()
	db, err := pgxpool.New(ctx, dbURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	if _, err := migrations.Apply(ctx, db); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(ctx, `TRUNCATE auth_attempts, sessions, users, oauth_states CASCADE`); err != nil {
		t.Fatal(err)
	}
	prov := httptest.NewServer(fake.handler(t))
	t.Cleanup(prov.Close)
	cat, _ := catalog.Default()
	svc := &auth.Service{DB: db, Caller: fixedCaller{}, SMS: fixedCaller{}, Secret: []byte("s")}
	o := &oauth.Service{DB: db, Providers: []oauth.Provider{
		oauth.VKID{ClientID: "42", Redirect: "vk42://vk.ru/blank.html", BaseURL: prov.URL},
		oauth.YandexID{ClientID: "ya", Redirect: "ru.svoi://oauth/yandex", OAuthURL: prov.URL, LoginURL: prov.URL},
	}}
	srv := httptest.NewServer(New(Deps{Catalog: cat, Auth: svc, OAuth: o, Log: slog.New(slog.NewTextHandler(io.Discard, nil))}))
	t.Cleanup(srv.Close)
	return srv
}

func TestOAuthLogin(t *testing.T) {
	fake := &fakeProvider{challenges: map[string]string{}, phone: "79145556677"}
	srv := oauthServer(t, fake)

	code, body, _ := call(t, srv, "GET", "/v1/auth/providers", "", nil)
	if code != 200 || len(body["items"].([]any)) != 2 {
		t.Fatalf("providers: %d %v", code, body)
	}

	// Пользователь «входит» у провайдера: провайдер запоминает challenge и выдаёт code.
	login := func(provider, authCode string) (state string) {
		t.Helper()
		code, body, _ := call(t, srv, "POST", "/v1/auth/oauth/"+provider+"/start", "", nil)
		if code != 200 {
			t.Fatalf("start %s: %d %v", provider, code, body)
		}
		u, _ := url.Parse(body["url"].(string))
		q := u.Query()
		if q.Get("code_challenge_method") != "S256" || q.Get("state") != body["state"] {
			t.Fatalf("ссылка авторизации: %s", u)
		}
		if scope := q.Get("scope"); scope != "phone" && scope != "login:default_phone" {
			t.Fatalf("просим лишнее: scope=%q", scope)
		}
		fake.challenges[authCode] = q.Get("code_challenge")
		return body["state"].(string)
	}

	state := login("vk", "c1")
	code, body, _ = call(t, srv, "POST", "/v1/auth/oauth/vk/finish", "", map[string]string{"state": state, "code": "c1", "device_id": "d1"})
	if code != 200 || body["token"] == "" || body["registered"] != false {
		t.Fatalf("finish vk: %d %v", code, body)
	}
	token := body["token"].(string)
	if code, _, _ := call(t, srv, "POST", "/v1/auth/register", token, map[string]any{
		"name": "Иван", "birth_date": "1990-01-01", "gender": "male", "city": "Чита",
		"consents": map[string]bool{"terms": true, "personal_data": true},
	}); code != 201 && code != 200 {
		t.Fatalf("регистрация после VK ID: %d", code)
	}

	// Повтор того же state не проходит — попытка одноразовая.
	if code, _, _ := call(t, srv, "POST", "/v1/auth/oauth/vk/finish", "", map[string]string{"state": state, "code": "c1", "device_id": "d1"}); code != 400 {
		t.Fatalf("повтор state: %d", code)
	}

	// Яндекс ID с тем же номером — тот же аккаунт, уже зарегистрированный.
	fake.phone = "+7 914 555-66-77"
	state = login("yandex", "c2")
	code, body, _ = call(t, srv, "POST", "/v1/auth/oauth/yandex/finish", "", map[string]string{"state": state, "code": "c2"})
	if code != 200 || body["registered"] != true {
		t.Fatalf("finish yandex: %d %v", code, body)
	}

	// Чужой code_verifier (подменённый код) — отказ.
	state = login("yandex", "c3")
	fake.challenges["c3"] = "другой"
	if code, _, _ := call(t, srv, "POST", "/v1/auth/oauth/yandex/finish", "", map[string]string{"state": state, "code": "c3"}); code != 400 {
		t.Fatalf("подмена кода: %d", code)
	}

	// В аккаунте нет номера.
	fake.phone = ""
	state = login("yandex", "c4")
	if code, body, _ := call(t, srv, "POST", "/v1/auth/oauth/yandex/finish", "", map[string]string{"state": state, "code": "c4"}); code != 422 {
		t.Fatalf("без номера: %d %v", code, body)
	}

	// Иностранный номер — нельзя (406-ФЗ), как и при входе по звонку.
	fake.phone = "+12025550100"
	state = login("vk", "c5")
	if code, _, _ := call(t, srv, "POST", "/v1/auth/oauth/vk/finish", "", map[string]string{"state": state, "code": "c5", "device_id": "d"}); code != 400 {
		t.Fatalf("иностранный номер: %d", code)
	}

	if code, _, _ := call(t, srv, "POST", "/v1/auth/oauth/google/start", "", nil); code != 404 {
		t.Fatalf("неизвестный провайдер: %d", code)
	}
}
