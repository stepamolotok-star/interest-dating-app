package httpapi

import (
	"bytes"
	"encoding/json"
	"image"
	"image/png"
	"io"
	"net/http"
	"strings"
	"testing"
)

func send(t *testing.T, method, url, token, ctype string, body []byte) (int, []byte, http.Header) {
	t.Helper()
	req, err := http.NewRequest(method, url, bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if ctype != "" {
		req.Header.Set("Content-Type", ctype)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(res.Body)
	return res.StatusCode, b, res.Header
}

// Загрузка фото как есть в теле запроса, раздача JPEG, модератор видит и убирает.
func TestPhotosHTTP(t *testing.T) {
	srv, _ := moderationServer(t)
	anna, _ := signUp(t, srv, "+79140001001", "Анна")
	igor, _ := signUp(t, srv, "+79140001002", "Игорь")

	var buf bytes.Buffer
	if err := png.Encode(&buf, image.NewRGBA(image.Rect(0, 0, 50, 80))); err != nil {
		t.Fatal(err)
	}
	code, body, _ := send(t, "POST", srv.URL+"/v1/me/photos", anna, "image/png", buf.Bytes())
	if code != 200 {
		t.Fatalf("загрузка: %d %s", code, body)
	}
	var p struct {
		ID string `json:"id"`
	}
	_ = json.Unmarshal(body, &p)

	code, body, _ = send(t, "POST", srv.URL+"/v1/me/photos", anna, "image/png", []byte("не картинка"))
	if code != 400 || !strings.Contains(string(body), "JPEG") {
		t.Fatalf("мусор: %d %s", code, body)
	}

	code, body, hdr := send(t, "GET", srv.URL+"/v1/photos/"+p.ID, igor, "", nil)
	if code != 200 || hdr.Get("Content-Type") != "image/jpeg" || len(body) < 100 || body[0] != 0xFF {
		t.Fatalf("раздача: %d %s %d", code, hdr.Get("Content-Type"), len(body))
	}
	if code, _, _ = send(t, "GET", srv.URL+"/v1/photos/"+p.ID, "", "", nil); code != 401 {
		t.Fatalf("без входа: %d", code)
	}
	if code, _, _ = send(t, "GET", srv.URL+"/v1/photos/not-a-uuid", igor, "", nil); code != 404 {
		t.Fatalf("плохой id: %d", code)
	}

	// Модератор.
	admin := func(method, path string, body []byte) (int, []byte) {
		c, b, _ := send(t, method, srv.URL+path, testAdminToken, "application/json", body)
		return c, b
	}
	if c, b := admin("GET", "/admin/api/photos/"+p.ID, nil); c != 200 || b[0] != 0xFF {
		t.Fatalf("модератор смотрит фото: %d", c)
	}
	if c, b := admin("POST", "/admin/api/photos/"+p.ID+"/remove", []byte(`{"note":"чужое фото"}`)); c != 204 {
		t.Fatalf("модератор убирает фото: %d %s", c, b)
	}
	if code, _, _ = send(t, "GET", srv.URL+"/v1/photos/"+p.ID, anna, "", nil); code != 404 {
		t.Fatalf("убранное фото: %d", code)
	}
	code, body, _ = send(t, "GET", srv.URL+"/v1/me/photos", anna, "", nil)
	if code != 200 || !strings.Contains(string(body), `"items":[]`) {
		t.Fatalf("список: %d %s", code, body)
	}
}
