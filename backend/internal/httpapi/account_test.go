package httpapi

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Удаление аккаунта убирает всё: анкету, фото, селфи, совпадения, переписку, жалобы автора.
// Номер свободен для новой регистрации.
func TestDeleteAccount(t *testing.T) {
	srv, db := moderationServer(t)
	ctx := t.Context()
	anna, annaID := signUp(t, srv, "+79140004001", "Анна")
	igor, igorID := signUp(t, srv, "+79140004002", "Игорь")

	// Фото и селфи на проверке.
	code, b, _ := send(t, "POST", srv.URL+"/v1/me/photos", anna, "image/png", pngBytes(t))
	if code != 200 {
		t.Fatalf("фото: %d %s", code, b)
	}
	_, vb, _ := send(t, "POST", srv.URL+"/v1/me/verification", anna, "application/json", nil)
	var v struct{ ID string }
	_ = json.Unmarshal(vb, &v)
	if code, b, _ := send(t, "POST", srv.URL+"/v1/me/verification/"+v.ID+"/selfie", anna, "image/png", pngBytes(t)); code != 200 {
		t.Fatalf("селфи: %d %s", code, b)
	}
	var files []string
	rows, _ := db.Query(ctx, `SELECT object_key FROM photos WHERE user_id = $1 UNION ALL
		SELECT object_key FROM photo_verifications WHERE user_id = $1`, annaID)
	for rows.Next() {
		var k string
		_ = rows.Scan(&k)
		files = append(files, k)
	}
	rows.Close()
	if len(files) != 2 {
		t.Fatalf("файлы: %v", files)
	}

	// Совпадение, сообщение, жалоба Анны на Игоря с решением модератора.
	a, bb := annaID, igorID
	if bb < a {
		a, bb = bb, a
	}
	var match string
	if err := db.QueryRow(ctx, `INSERT INTO matches (user_a, user_b, goal) VALUES ($1, $2, 'hobby') RETURNING id`, a, bb).Scan(&match); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(ctx, `INSERT INTO messages (match_id, sender, body) VALUES ($1, $2, 'Привет')`, match, annaID); err != nil {
		t.Fatal(err)
	}
	if code, body, _ := call(t, srv, "POST", "/v1/users/"+igorID+"/report", anna, map[string]string{"reason": "spam"}); code != 200 {
		t.Fatalf("жалоба: %d %v", code, body)
	}
	_, q, _ := call(t, srv, "GET", "/admin/api/reports", testAdminToken, nil)
	rid := int(q["items"].([]any)[0].(map[string]any)["id"].(float64))
	if code, body, _ := call(t, srv, "POST", "/admin/api/reports/"+itoa(rid)+"/resolve", testAdminToken,
		map[string]any{"action": "warn"}); code != 204 {
		t.Fatalf("решение: %d %v", code, body)
	}

	if code, _, _ := send(t, "DELETE", srv.URL+"/v1/me", anna, "", nil); code != 204 {
		t.Fatalf("удаление: %d", code)
	}
	if code, _, _ := send(t, "GET", srv.URL+"/v1/me", anna, "", nil); code != 401 {
		t.Fatalf("сессия после удаления: %d", code)
	}
	for _, k := range files {
		if _, err := os.Stat(filepath.Join(testStoreDir, k)); !os.IsNotExist(err) {
			t.Fatalf("файл %s остался: %v", k, err)
		}
	}
	var left int
	_ = db.QueryRow(ctx, `SELECT (SELECT count(*) FROM matches WHERE id = $1) + (SELECT count(*) FROM reports WHERE reporter = $2)
		+ (SELECT count(*) FROM consents WHERE user_id = $2) + (SELECT count(*) FROM sessions WHERE phone_e164 = '+79140004001')
		+ (SELECT count(*) FROM auth_attempts WHERE phone_e164 = '+79140004001')`, match, annaID).Scan(&left)
	if left != 0 {
		t.Fatalf("осталось записей: %d", left)
	}
	// Решение о нарушителе (Игоре) остаётся, ссылка на удалённую жалобу — пустая.
	var actions int
	_ = db.QueryRow(ctx, `SELECT count(*) FROM moderation_actions WHERE target = $1 AND action = 'warn' AND report_id IS NULL`, igorID).Scan(&actions)
	if actions != 1 {
		t.Fatalf("журнал модерации: %d", actions)
	}
	if code, body, _ := call(t, srv, "GET", "/v1/matches", igor, nil); code != 200 || len(body["items"].([]any)) != 0 {
		t.Fatalf("у Игоря осталось совпадение: %d %v", code, body)
	}

	// Номер свободен: можно зарегистрироваться заново, это новый аккаунт.
	_, again := signUp(t, srv, "+79140004001", "Анна")
	if again == annaID {
		t.Fatal("после удаления должен быть новый аккаунт")
	}
}

func TestLegalPages(t *testing.T) {
	srv, _ := moderationServer(t)
	code, b, h := send(t, "GET", srv.URL+"/legal/privacy", "", "", nil)
	page := string(b)
	if code != 200 || !strings.Contains(page, "<h1>Политика обработки персональных данных</h1>") ||
		!strings.Contains(page, "Иванов Иван Иванович") || !strings.Contains(page, "help@example.ru") ||
		strings.Contains(page, "{{") || !strings.Contains(h.Get("Content-Security-Policy"), "default-src 'none'") {
		t.Fatalf("политика: %d %s", code, page[:min(300, len(page))])
	}
	if code, b, _ = send(t, "GET", srv.URL+"/legal/", "", "", nil); code != 200 || strings.Count(string(b), "<li>") != 6 {
		t.Fatalf("список: %d %s", code, b)
	}
	if code, _, _ = send(t, "GET", srv.URL+"/legal/..%2Fadmin%2Fapp.js", "", "", nil); code != 404 {
		t.Fatal("выход за пределы /legal")
	}
	if code, _, _ = send(t, "GET", srv.URL+"/legal/nope", "", "", nil); code != 404 {
		t.Fatalf("нет такого: %d", code)
	}
}
