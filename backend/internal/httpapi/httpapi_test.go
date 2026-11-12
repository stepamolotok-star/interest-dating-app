package httpapi

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/catalog"
)

func newServer(t *testing.T) *httptest.Server {
	t.Helper()
	cat, err := catalog.Default()
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(New(Deps{Catalog: cat, Log: slog.New(slog.NewTextHandler(io.Discard, nil))}))
	t.Cleanup(srv.Close)
	return srv
}

func get(t *testing.T, srv *httptest.Server, path string) (int, map[string]any) {
	t.Helper()
	resp, err := http.Get(srv.URL + path)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var body map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("%s: не JSON: %v", path, err)
	}
	return resp.StatusCode, body
}

func TestHealth(t *testing.T) {
	code, body := get(t, newServer(t), "/healthz")
	if code != 200 || body["status"] != "ok" {
		t.Fatalf("%d %v", code, body)
	}
}

func TestCategoriesAndChildren(t *testing.T) {
	srv := newServer(t)
	code, body := get(t, srv, "/v1/interests/categories")
	if code != 200 || len(body["items"].([]any)) < 20 {
		t.Fatalf("категории: %d %v", code, body)
	}
	code, body = get(t, srv, "/v1/interests/transport.moto/children")
	if code != 200 || len(body["items"].([]any)) != 4 {
		t.Fatalf("подкатегория мотоциклов: %d %v", code, body)
	}
	if code, _ = get(t, srv, "/v1/interests/нет-такого/children"); code != 404 {
		t.Fatalf("ждали 404, получили %d", code)
	}
}

func TestSearch(t *testing.T) {
	srv := newServer(t)
	code, body := get(t, srv, "/v1/interests/search?q="+url.QueryEscape("эндура"))
	if code != 200 {
		t.Fatalf("%d %v", code, body)
	}
	first := body["items"].([]any)[0].(map[string]any)
	if first["id"] != "transport.moto.enduro" || len(first["path"].([]any)) != 3 {
		t.Fatalf("первый результат: %v", first)
	}
	if code, _ = get(t, srv, "/v1/interests/search?q=a"); code != 400 {
		t.Fatalf("короткий запрос: ждали 400, получили %d", code)
	}
}
