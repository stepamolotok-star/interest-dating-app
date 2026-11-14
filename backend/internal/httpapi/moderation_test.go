package httpapi

import (
	"context"
	"crypto/sha256"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/auth"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/catalog"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/chat"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/cities"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/feed"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/moderation"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/profile"
	"github.com/stepamolotok-star/interest-dating-app/backend/migrations"
)

const testAdminToken = "test-admin-token-0123456789abcdef"

func moderationServer(t *testing.T) (*httptest.Server, *pgxpool.Pool) {
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
	if _, err := db.Exec(ctx, `TRUNCATE auth_attempts, sessions, users, banned_phones CASCADE`); err != nil {
		t.Fatal(err)
	}
	cat, _ := catalog.Default()
	cityCat, _ := cities.Default()
	prof := &profile.Service{DB: db, Catalog: cat}
	if err := prof.SyncCatalog(ctx); err != nil {
		t.Fatal(err)
	}
	secret := []byte("s")
	srv := httptest.NewServer(New(Deps{
		Catalog: cat, Cities: cityCat, Log: slog.New(slog.NewTextHandler(io.Discard, nil)),
		Auth:       &auth.Service{DB: db, Caller: fixedCaller{}, SMS: fixedCaller{}, Secret: secret, Cities: cityCat},
		Profile:    prof,
		Feed:       &feed.Service{DB: db, Catalog: cat},
		Chat:       &chat.Service{DB: db, Catalog: cat},
		Moderation: &moderation.Service{DB: db, PhoneSecret: secret},
		AdminToken: testAdminToken,
	}))
	t.Cleanup(srv.Close)
	return srv, db
}

// signUp проходит вход и регистрацию, возвращает токен и id.
func signUp(t *testing.T, srv *httptest.Server, phone, name string) (token, id string) {
	t.Helper()
	if code, body, _ := call(t, srv, "POST", "/v1/auth/start", "", map[string]string{"phone": phone}); code != 200 {
		t.Fatalf("start %s: %d %v", phone, code, body)
	}
	code, body, _ := call(t, srv, "POST", "/v1/auth/verify", "", map[string]string{"phone": phone, "code": "7315"})
	if code != 200 {
		t.Fatalf("verify %s: %d %v", phone, code, body)
	}
	token = body["token"].(string)
	reg := map[string]any{"name": name, "birth_date": "1995-03-10", "gender": "male", "city": "Чита",
		"consents": map[string]bool{"terms": true, "personal_data": true}}
	if code, body, _ = call(t, srv, "POST", "/v1/auth/register", token, reg); code != 201 {
		t.Fatalf("register %s: %d %v", name, code, body)
	}
	_, me, _ := call(t, srv, "GET", "/v1/me", token, nil)
	return token, me["user_id"].(string)
}

func TestModerationFlow(t *testing.T) {
	srv, db := moderationServer(t)
	ctx := context.Background()
	badToken, bad := signUp(t, srv, "+79140000001", "Нарушитель")
	var reporters []string
	for i, p := range []string{"+79140000002", "+79140000003", "+79140000004"} {
		tok, _ := signUp(t, srv, p, []string{"Анна", "Вера", "Галя"}[i])
		reporters = append(reporters, tok)
	}

	// Три срочные жалобы от разных людей — нарушитель скрыт из ленты до решения.
	for i, tok := range reporters {
		code, body, _ := call(t, srv, "POST", "/v1/users/"+bad+"/report", tok,
			map[string]string{"reason": "threat", "comment": "пишет угрозы"})
		if code != 200 || body["urgent"] != true {
			t.Fatalf("жалоба %d: %d %v", i, code, body)
		}
	}
	var onHold bool
	_ = db.QueryRow(ctx, `SELECT on_hold FROM users WHERE id = $1`, bad).Scan(&onHold)
	if !onHold {
		t.Fatal("после трёх срочных жалоб человек должен быть скрыт до проверки")
	}

	// Без ключа модератора — нельзя; с неправильным — тоже.
	if code, _, _ := call(t, srv, "GET", "/admin/api/reports", "", nil); code != 401 {
		t.Fatalf("без ключа: %d", code)
	}
	if code, _, _ := call(t, srv, "GET", "/admin/api/reports", "wrong-token-wrong-token-wrong", nil); code != 401 {
		t.Fatalf("неверный ключ: %d", code)
	}
	code, body, _ := call(t, srv, "GET", "/admin/api/reports", testAdminToken, nil)
	items := body["items"].([]any)
	if code != 200 || len(items) != 3 {
		t.Fatalf("очередь: %d %v", code, body)
	}
	first := items[0].(map[string]any)
	if first["urgent"] != true || first["target_reporters"].(float64) != 3 {
		t.Fatalf("жалоба в очереди: %v", first)
	}
	reportID := int(first["id"].(float64))
	path := "/admin/api/reports/" + itoa(reportID)
	if code, body, _ = call(t, srv, "GET", path, testAdminToken, nil); code != 200 || len(body["other_reports"].([]any)) != 2 {
		t.Fatalf("карточка жалобы: %d %v", code, body)
	}

	// Предупреждение закрывает все жалобы на человека и показывается ему один раз.
	if code, body, _ = call(t, srv, "POST", path+"/resolve", testAdminToken,
		map[string]any{"action": "warn", "note": "Без угроз, пожалуйста"}); code != 204 {
		t.Fatalf("предупреждение: %d %v", code, body)
	}
	if code, body, _ = call(t, srv, "POST", path+"/resolve", testAdminToken, map[string]any{"action": "warn"}); code != 409 {
		t.Fatalf("повторное решение: %d %v", code, body)
	}
	if _, body, _ = call(t, srv, "GET", "/admin/api/reports", testAdminToken, nil); len(body["items"].([]any)) != 0 {
		t.Fatalf("после решения очередь пуста: %v", body)
	}
	_ = db.QueryRow(ctx, `SELECT on_hold FROM users WHERE id = $1`, bad).Scan(&onHold)
	if onHold {
		t.Fatal("после решения человек снова виден")
	}
	if _, body, _ = call(t, srv, "GET", "/v1/me", badToken, nil); body["warning"] != "Модератор проверил жалобы на вас: «Без угроз, пожалуйста». При повторных нарушениях аккаунт заблокируют." {
		t.Fatalf("предупреждение в /me: %v", body)
	}
	if code, _, _ = call(t, srv, "POST", "/v1/me/warning/ack", badToken, nil); code != 204 {
		t.Fatalf("прочитал предупреждение: %d", code)
	}
	if _, body, _ = call(t, srv, "GET", "/v1/me", badToken, nil); body["warning"] != nil {
		t.Fatalf("предупреждение показывается один раз: %v", body)
	}

	// Новая жалоба → блокировка навсегда: вход закрыт, номер не зарегистрировать снова.
	call(t, srv, "POST", "/v1/users/"+bad+"/report", reporters[0], map[string]string{"reason": "spam"})
	_, body, _ = call(t, srv, "GET", "/admin/api/reports", testAdminToken, nil)
	banID := itoa(int(body["items"].([]any)[0].(map[string]any)["id"].(float64)))
	if code, body, _ = call(t, srv, "POST", "/admin/api/reports/"+banID+"/resolve", testAdminToken,
		map[string]any{"action": "ban", "note": "спам после предупреждения"}); code != 204 {
		t.Fatalf("бан: %d %v", code, body)
	}
	code, body, _ = call(t, srv, "GET", "/v1/me", badToken, nil)
	if code != 403 || body["blocked"] != true || body["until"] != nil {
		t.Fatalf("после бана старый токен: %d %v", code, body)
	}
	code, body, _ = call(t, srv, "POST", "/v1/auth/start", "", map[string]string{"phone": "8 914 000-00-01"})
	if code != 403 || body["blocked"] != true {
		t.Fatalf("повторный вход с заблокированного номера: %d %v", code, body)
	}

	// Разблокировка возвращает номер.
	if code, _, _ = call(t, srv, "POST", "/admin/api/users/"+bad+"/unban", testAdminToken, map[string]string{}); code != 204 {
		t.Fatalf("разблокировка: %d", code)
	}
	if code, body, _ = call(t, srv, "POST", "/v1/auth/start", "", map[string]string{"phone": "+79140000001"}); code == 403 {
		t.Fatalf("после разблокировки вход открыт: %d %v", code, body)
	}

	// Временная блокировка: 403 со сроком.
	call(t, srv, "POST", "/v1/users/"+bad+"/report", reporters[1], map[string]string{"reason": "harassment"})
	_, body, _ = call(t, srv, "GET", "/admin/api/reports", testAdminToken, nil)
	susID := itoa(int(body["items"].([]any)[0].(map[string]any)["id"].(float64)))
	if code, _, _ = call(t, srv, "POST", "/admin/api/reports/"+susID+"/resolve", testAdminToken,
		map[string]any{"action": "suspend", "days": 0}); code != 400 {
		t.Fatalf("срок 0 дней: %d", code)
	}
	if code, _, _ = call(t, srv, "POST", "/admin/api/reports/"+susID+"/resolve", testAdminToken,
		map[string]any{"action": "suspend", "days": 7}); code != 204 {
		t.Fatalf("блокировка на 7 дней: %d", code)
	}
	newToken := loginToken(t, db)
	code, body, _ = call(t, srv, "GET", "/v1/me", newToken(bad), nil)
	if code != 403 || body["blocked"] != true || body["until"] == nil {
		t.Fatalf("временная блокировка: %d %v", code, body)
	}

	// Страница модератора — со строгими заголовками.
	resp, err := http.Get(srv.URL + "/admin/")
	if err != nil {
		t.Fatal(err)
	}
	page, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || !strings.Contains(string(page), "Модерация") ||
		!strings.Contains(resp.Header.Get("Content-Security-Policy"), "frame-ancestors 'none'") {
		t.Fatalf("страница модератора: %d %q", resp.StatusCode, resp.Header.Get("Content-Security-Policy"))
	}
}

// loginToken выдаёт сессию напрямую в базе — так проверяем, что блокировка действует и на новые сессии.
func loginToken(t *testing.T, db *pgxpool.Pool) func(userID string) string {
	return func(userID string) string {
		t.Helper()
		tok := "direct-session-token-" + userID
		h := tokenHashForTest(tok)
		if _, err := db.Exec(context.Background(), `INSERT INTO sessions (token_hash, phone_e164, user_id, expires_at)
			SELECT $1, phone_e164, id, now() + interval '1 day' FROM users WHERE id = $2`, h, userID); err != nil {
			t.Fatal(err)
		}
		return tok
	}
}

func itoa(n int) string { return strconv.Itoa(n) }

func tokenHashForTest(token string) []byte {
	h := sha256.Sum256([]byte(token))
	return h[:]
}
