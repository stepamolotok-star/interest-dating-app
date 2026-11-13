package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/auth"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/catalog"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/cities"
	"github.com/stepamolotok-star/interest-dating-app/backend/migrations"
)

type fixedCaller struct{}

func (fixedCaller) FlashCall(context.Context, string) (string, error) { return "7315", nil }
func (fixedCaller) SendCode(context.Context, string, string) error    { return nil }

func authServer(t *testing.T) *httptest.Server {
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
	cat, _ := catalog.Default()
	cityCat, _ := cities.Default()
	svc := &auth.Service{DB: db, Caller: fixedCaller{}, SMS: fixedCaller{}, Secret: []byte("s"), Cities: cityCat}
	srv := httptest.NewServer(New(Deps{Catalog: cat, Cities: cityCat, Auth: svc, Log: slog.New(slog.NewTextHandler(io.Discard, nil))}))
	t.Cleanup(srv.Close)
	return srv
}

func call(t *testing.T, srv *httptest.Server, method, path, token string, body any) (int, map[string]any, http.Header) {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		_ = json.NewEncoder(&buf).Encode(body)
	}
	req, _ := http.NewRequest(method, srv.URL+path, &buf)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out, resp.Header
}

func TestAuthFlowOverHTTP(t *testing.T) {
	srv := authServer(t)

	code, body, _ := call(t, srv, "POST", "/v1/auth/start", "", map[string]string{"phone": "+7 495 123-45-67"})
	if code != 400 {
		t.Fatalf("городской номер: %d %v", code, body)
	}
	code, body, _ = call(t, srv, "POST", "/v1/auth/start", "", map[string]string{"phone": "+7 914 555-66-77"})
	if code != 200 || body["method"] != "flash_call" || body["code_length"].(float64) != 4 {
		t.Fatalf("start: %d %v", code, body)
	}
	code, _, hdr := call(t, srv, "POST", "/v1/auth/start", "", map[string]string{"phone": "+7 914 555-66-77"})
	if code != 429 || hdr.Get("Retry-After") == "" {
		t.Fatalf("повтор сразу: %d, Retry-After=%q", code, hdr.Get("Retry-After"))
	}
	code, body, _ = call(t, srv, "POST", "/v1/auth/verify", "", map[string]string{"phone": "89145556677", "code": "1111"})
	if code != 400 {
		t.Fatalf("неверный код: %d %v", code, body)
	}
	code, body, _ = call(t, srv, "POST", "/v1/auth/verify", "", map[string]string{"phone": "89145556677", "code": "7315"})
	if code != 200 || body["registered"] != false {
		t.Fatalf("verify: %d %v", code, body)
	}
	token := body["token"].(string)

	if code, _, _ = call(t, srv, "GET", "/v1/me", token, nil); code != 403 {
		t.Fatalf("до регистрации /me: %d", code)
	}
	reg := map[string]any{"name": "Анна", "birth_date": "1997-05-20", "gender": "female", "city": "Чита",
		"consents": map[string]bool{"terms": true, "personal_data": true}}
	if code, body, _ = call(t, srv, "POST", "/v1/auth/register", token, reg); code != 201 {
		t.Fatalf("register: %d %v", code, body)
	}
	code, body, _ = call(t, srv, "GET", "/v1/me", token, nil)
	if code != 200 || body["name"] != "Анна" || body["age_verified"] != false {
		t.Fatalf("me: %d %v", code, body)
	}
	if code, _, _ = call(t, srv, "POST", "/v1/auth/logout", token, nil); code != 204 {
		t.Fatalf("logout: %d", code)
	}
	if code, _, _ = call(t, srv, "GET", "/v1/me", token, nil); code != 401 {
		t.Fatalf("после выхода: %d", code)
	}
	if code, _, _ = call(t, srv, "GET", "/v1/me", "", nil); code != 401 {
		t.Fatalf("без токена: %d", code)
	}
}

func TestCitiesOverHTTP(t *testing.T) {
	srv := authServer(t)
	code, body, _ := call(t, srv, "GET", "/v1/cities/search?q=советск", "", nil)
	items := body["items"].([]any)
	if code != 200 || len(items) < 3 {
		t.Fatalf("поиск: %d %v", code, body)
	}
	for _, it := range items[:3] {
		if it.(map[string]any)["name"] != "Советск" {
			t.Fatalf("точные совпадения — первыми: %v", items)
		}
	}
	first := items[0].(map[string]any)
	if first["name"] != "Советск" || first["region"] == "" {
		t.Fatalf("у одноимённых городов есть регион: %v", first)
	}

	// Вход и регистрация: одноимённый город текстом — нельзя, по коду — можно.
	call(t, srv, "POST", "/v1/auth/start", "", map[string]string{"phone": "+79145550001"})
	_, body, _ = call(t, srv, "POST", "/v1/auth/verify", "", map[string]string{"phone": "+79145550001", "code": "7315"})
	token := body["token"].(string)
	reg := map[string]any{"name": "Олег", "birth_date": "1990-01-01", "gender": "male", "city": "Советск",
		"consents": map[string]bool{"terms": true, "personal_data": true}}
	if code, body, _ := call(t, srv, "POST", "/v1/auth/register", token, reg); code != 400 || body["field"] != "city" {
		t.Fatalf("неоднозначный город: %d %v", code, body)
	}
	reg["city_id"] = first["id"]
	if code, body, _ := call(t, srv, "POST", "/v1/auth/register", token, reg); code != 201 && code != 200 {
		t.Fatalf("регистрация с городом из списка: %d %v", code, body)
	}
	_, me, _ := call(t, srv, "GET", "/v1/me", token, nil)
	if me["city"] != "Советск" || me["city_id"] != first["id"] || me["region"] != first["region"] {
		t.Fatalf("me: %v", me)
	}
}
