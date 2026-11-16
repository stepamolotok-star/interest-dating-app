package notify

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

// RuStore отправляет через RuStore Push (API совместим с FCM v1).
// ProjectID и сервисный токен — в консоли RuStore: приложение → Push-уведомления → Проекты.
type RuStore struct {
	ProjectID string
	Token     string
	// Base — адрес API; пусто — боевой https://vkpns.rustore.ru.
	Base   string
	Client *http.Client
}

// Канал уведомлений Android: приложение создаёт его заранее со звуком и важностью.
const channelID = "svoi_default"

func (r RuStore) Send(ctx context.Context, token string, m Message) error {
	base := r.Base
	if base == "" {
		base = "https://vkpns.rustore.ru"
	}
	client := r.Client
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	data := map[string]string{"kind": string(m.Kind)}
	for k, v := range m.Data {
		data[k] = v
	}
	body, err := json.Marshal(map[string]any{"message": map[string]any{
		"token":        token,
		"data":         data,
		"notification": map[string]string{"title": m.Title, "body": m.Body},
		"android": map[string]any{
			"ttl":          "86400s", // через сутки о «рядом» и «новом сообщении» напоминать поздно
			"notification": map[string]string{"title": m.Title, "body": m.Body, "channel_id": channelID},
		},
	}})
	if err != nil {
		return err
	}
	u := base + "/v1/projects/" + url.PathEscape(r.ProjectID) + "/messages:send"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+r.Token)
	res, err := client.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	msg, _ := io.ReadAll(io.LimitReader(res.Body, 2048))
	switch {
	case res.StatusCode == http.StatusOK:
		return nil
	case res.StatusCode == http.StatusNotFound, res.StatusCode == http.StatusBadRequest && bytes.Contains(msg, []byte("token")):
		// 404 — токен истёк, 400 о токене — он недействителен.
		return ErrBadToken
	default:
		return fmt.Errorf("rustore push: %d %s", res.StatusCode, msg)
	}
}
