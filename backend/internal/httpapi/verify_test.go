package httpapi

import (
	"bytes"
	"encoding/json"
	"image"
	"image/png"
	"strings"
	"testing"
)

func pngBytes(t *testing.T) []byte {
	t.Helper()
	var buf bytes.Buffer
	if err := png.Encode(&buf, image.NewRGBA(image.Rect(0, 0, 40, 60))); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// Проверка по селфи: жест → селфи → модератор → значок; удалили все фото — значок снят.
func TestPhotoVerification(t *testing.T) {
	srv, db := moderationServer(t)
	anna, _ := signUp(t, srv, "+79140003001", "Анна")
	type status struct {
		Status, ID, Gesture, Note string
	}
	call := func(method, path string, body []byte) (int, status) {
		t.Helper()
		ctype := "application/json"
		if strings.HasSuffix(path, "/selfie") {
			ctype = "image/png"
		}
		code, b, _ := send(t, method, srv.URL+path, anna, ctype, body)
		var st status
		_ = json.Unmarshal(b, &st)
		if code >= 400 {
			st.Note = string(b)
		}
		return code, st
	}
	admin := func(method, path string, body []byte) (int, []byte) {
		c, b, _ := send(t, method, srv.URL+path, testAdminToken, "application/json", body)
		return c, b
	}
	me := func() bool {
		_, b, _ := send(t, "GET", srv.URL+"/v1/me", anna, "", nil)
		var m struct {
			PhotoVerified bool `json:"photo_verified"`
		}
		_ = json.Unmarshal(b, &m)
		return m.PhotoVerified
	}

	if _, st := call("GET", "/v1/me/verification", nil); st.Status != "none" {
		t.Fatalf("сначала: %+v", st)
	}
	if code, st := call("POST", "/v1/me/verification", nil); code != 400 || !strings.Contains(st.Note, "фото") {
		t.Fatalf("без фото: %d %+v", code, st)
	}
	code, b, _ := send(t, "POST", srv.URL+"/v1/me/photos", anna, "image/png", pngBytes(t))
	if code != 200 {
		t.Fatalf("фото: %d %s", code, b)
	}
	var photo struct{ ID string }
	_ = json.Unmarshal(b, &photo)

	_, first := call("POST", "/v1/me/verification", nil)
	if first.Status != "requested" || first.Gesture == "" || first.ID == "" {
		t.Fatalf("жест: %+v", first)
	}
	// Повторный запрос не перебирает жесты.
	if _, again := call("POST", "/v1/me/verification", nil); again.ID != first.ID || again.Gesture != first.Gesture {
		t.Fatalf("жест сменился: %+v → %+v", first, again)
	}
	if code, st := call("POST", "/v1/me/verification/"+first.ID+"/selfie", pngBytes(t)); code != 200 || st.Status != "pending" {
		t.Fatalf("селфи: %d %+v", code, st)
	}
	if code, _ := call("POST", "/v1/me/verification/"+first.ID+"/selfie", pngBytes(t)); code != 400 {
		t.Fatalf("второе селфи на ту же попытку: %d", code)
	}

	// Модератор: очередь, селфи, отказ с причиной.
	c, qb := admin("GET", "/admin/api/verifications", nil)
	var q struct {
		Items []struct {
			ID, Name, Gesture string
			Photos            []string
		}
		Reasons []string
	}
	_ = json.Unmarshal(qb, &q)
	if c != 200 || len(q.Items) != 1 || q.Items[0].Name != "Анна" || q.Items[0].Gesture != first.Gesture ||
		len(q.Items[0].Photos) != 1 || len(q.Reasons) == 0 {
		t.Fatalf("очередь: %d %s", c, qb)
	}
	if c, sb := admin("GET", "/admin/api/verifications/"+first.ID+"/selfie", nil); c != 200 || sb[0] != 0xFF {
		t.Fatalf("селфи модератору: %d", c)
	}
	if c, b := admin("POST", "/admin/api/verifications/"+first.ID+"/decide", []byte(`{"approve":false,"note":"На селфи другой жест"}`)); c != 204 {
		t.Fatalf("отказ: %d %s", c, b)
	}
	if c, _ := admin("GET", "/admin/api/verifications/"+first.ID+"/selfie", nil); c != 404 {
		t.Fatalf("селфи после решения должно удаляться: %d", c)
	}
	if _, st := call("GET", "/v1/me/verification", nil); st.Status != "rejected" || st.Note != "На селфи другой жест" {
		t.Fatalf("после отказа: %+v", st)
	}
	if me() {
		t.Fatal("после отказа значка нет")
	}

	// Вторая попытка — другой жест, подтверждение.
	_, second := call("POST", "/v1/me/verification", nil)
	if second.ID == first.ID || second.Gesture == first.Gesture {
		t.Fatalf("новая попытка: %+v", second)
	}
	call("POST", "/v1/me/verification/"+second.ID+"/selfie", pngBytes(t))
	if c, b := admin("POST", "/admin/api/verifications/"+second.ID+"/decide", []byte(`{"approve":true}`)); c != 204 {
		t.Fatalf("подтверждение: %d %s", c, b)
	}
	if _, st := call("GET", "/v1/me/verification", nil); st.Status != "approved" || !me() {
		t.Fatalf("после подтверждения: %+v %v", st, me())
	}
	if c, b := admin("GET", "/admin/api/stats", nil); c != 200 || !strings.Contains(string(b), `"verifications":0`) {
		t.Fatalf("статистика: %s", b)
	}

	// Удалили все фото — значок снят, проверяться заново.
	if code, _, _ := send(t, "DELETE", srv.URL+"/v1/me/photos/"+photo.ID, anna, "", nil); code != 204 {
		t.Fatalf("удаление фото: %d", code)
	}
	if _, st := call("GET", "/v1/me/verification", nil); st.Status != "none" || me() {
		t.Fatalf("без фото: %+v", st)
	}

	// Не больше 5 попыток в сутки.
	if _, err := db.Exec(t.Context(), `INSERT INTO photo_verifications (user_id, gesture, status)
		SELECT u.id, 'thumb', 'rejected' FROM users u, generate_series(1, 5) WHERE u.phone_e164 = '+79140003001'`); err != nil {
		t.Fatal(err)
	}
	send(t, "POST", srv.URL+"/v1/me/photos", anna, "image/png", pngBytes(t))
	if code, st := call("POST", "/v1/me/verification", nil); code != 429 {
		t.Fatalf("предел попыток: %d %+v", code, st)
	}
}
