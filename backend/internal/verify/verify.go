// Package verify — проверка фото по селфи.
//
// Человек получает случайный жест, делает селфи и отправляет. Модератор сравнивает
// лицо с фото анкеты и проверяет жест (его не подготовить заранее чужой фотографией).
// Подтвердил — у анкеты значок «Фото проверено» и доступ к «Без обязательств».
// Селфи видит только модератор и только до решения: потом файл удаляется.
package verify

import (
	"context"
	"errors"
	"math/rand/v2"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/limits"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/photos"
)

// Gesture — что показать на селфи.
type Gesture struct {
	ID   string `json:"id"`
	Text string `json:"text"`
}

// Gestures — простые жесты, которые видно на любом селфи и легко повторить одной рукой.
var Gestures = []Gesture{
	{"peace", "Покажите два пальца — «победа» — рядом с лицом"},
	{"thumb", "Поднимите большой палец вверх рядом с лицом"},
	{"chin", "Коснитесь подбородка указательным пальцем"},
	{"palm", "Приложите открытую ладонь к щеке"},
	{"ear", "Коснитесь уха рукой"},
	{"three", "Покажите три пальца рядом с лицом"},
}

func gestureText(id string) string {
	for _, g := range Gestures {
		if g.ID == id {
			return g.Text
		}
	}
	return ""
}

// Сколько живёт выданный жест: дольше — выдаём новый.
const gestureTTL = 30 * time.Minute

// Причины отказа, из которых выбирает модератор; можно написать свою.
var Reasons = []string{
	"Лицо на селфи не совпадает с фото анкеты",
	"На селфи другой жест",
	"Лицо плохо видно — снимите при хорошем свете, без очков и маски",
	"Это фото экрана или распечатки, а не селфи",
}

var (
	ErrNoPhotos = &photos.Error{Message: "Сначала добавьте фото в анкету — с ними модератор сравнит селфи."}
	ErrNotFound = errors.New("проверка не найдена")
	ErrState    = &photos.Error{Message: "Эта попытка уже отправлена — обновите экран."}
)

// Status — состояние проверки для приложения.
type Status struct {
	// none — не проверялся; requested — выдан жест, ждём селфи; pending — у модератора;
	// approved — фото проверено; rejected — отказ (см. Note), можно снова.
	Status  string `json:"status"`
	ID      string `json:"id,omitempty"`
	Gesture string `json:"gesture,omitempty"`
	Note    string `json:"note,omitempty"`
}

// Service — проверка по селфи.
type Service struct {
	DB    *pgxpool.Pool
	Store photos.Store
	// Pick выбирает жест; в тестах подменяется. По умолчанию — случайный, не как в прошлый раз.
	Pick func(prev string) Gesture
}

func (s *Service) pick(prev string) Gesture {
	if s.Pick != nil {
		return s.Pick(prev)
	}
	for {
		g := Gestures[rand.IntN(len(Gestures))]
		if g.ID != prev {
			return g
		}
	}
}

// Get — текущее состояние.
func (s *Service) Get(ctx context.Context, userID string) (Status, error) {
	var verified bool
	if err := s.DB.QueryRow(ctx, `SELECT photo_verified_at IS NOT NULL FROM users WHERE id = $1`, userID).Scan(&verified); err != nil {
		return Status{}, err
	}
	if verified {
		return Status{Status: "approved"}, nil
	}
	var st Status
	var gesture string
	var created time.Time
	err := s.DB.QueryRow(ctx, `SELECT id, status, gesture, note, created_at FROM photo_verifications
		WHERE user_id = $1 ORDER BY created_at DESC LIMIT 1`, userID).Scan(&st.ID, &st.Status, &gesture, &st.Note, &created)
	if errors.Is(err, pgx.ErrNoRows) {
		return Status{Status: "none"}, nil
	}
	if err != nil {
		return Status{}, err
	}
	switch st.Status {
	case "requested":
		if time.Since(created) > gestureTTL {
			return Status{Status: "none"}, nil
		}
		st.Gesture = gestureText(gesture)
	case "approved":
		// Значок сняли (удалили все фото) — проверяться заново.
		return Status{Status: "none"}, nil
	}
	if st.Status != "rejected" {
		st.Note = ""
	}
	return st, nil
}

// Start выдаёт жест. Если свежий жест уже выдан, возвращает его же — чтобы нельзя было
// перебирать жесты, пока не выпадет тот, что есть на старой фотографии.
func (s *Service) Start(ctx context.Context, userID string) (Status, error) {
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return Status{}, err
	}
	defer tx.Rollback(ctx)
	var verified bool
	var nphotos int
	if err := tx.QueryRow(ctx, `SELECT photo_verified_at IS NOT NULL, (SELECT count(*) FROM photos WHERE user_id = $1)
		FROM users WHERE id = $1 FOR UPDATE`, userID).Scan(&verified, &nphotos); err != nil {
		return Status{}, err
	}
	if verified {
		return Status{Status: "approved"}, nil
	}
	if nphotos == 0 {
		return Status{}, ErrNoPhotos
	}
	var id, status, gesture string
	var created time.Time
	err = tx.QueryRow(ctx, `SELECT id, status, gesture, created_at FROM photo_verifications
		WHERE user_id = $1 ORDER BY created_at DESC LIMIT 1`, userID).Scan(&id, &status, &gesture, &created)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return Status{}, err
	}
	if status == "pending" {
		return Status{Status: "pending", ID: id}, nil
	}
	if status == "requested" && time.Since(created) <= gestureTTL {
		return Status{Status: "requested", ID: id, Gesture: gestureText(gesture)}, nil
	}
	var today int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM photo_verifications
		WHERE user_id = $1 AND created_at > now() - interval '24 hours'`, userID).Scan(&today); err != nil {
		return Status{}, err
	}
	if today >= limits.VerificationsPerDay {
		return Status{}, limits.ErrVerifications
	}
	g := s.pick(gesture)
	if err := tx.QueryRow(ctx, `INSERT INTO photo_verifications (user_id, gesture) VALUES ($1, $2) RETURNING id`,
		userID, g.ID).Scan(&id); err != nil {
		return Status{}, err
	}
	return Status{Status: "requested", ID: id, Gesture: g.Text}, tx.Commit(ctx)
}

// Submit принимает селфи для выданного жеста и отправляет модератору.
func (s *Service) Submit(ctx context.Context, userID, id string, data []byte) (Status, error) {
	jpg, err := photos.Prepare(data)
	if err != nil {
		return Status{}, err
	}
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return Status{}, err
	}
	defer tx.Rollback(ctx)
	var status string
	var created time.Time
	err = tx.QueryRow(ctx, `SELECT status, created_at FROM photo_verifications WHERE id = $1 AND user_id = $2 FOR UPDATE`,
		id, userID).Scan(&status, &created)
	if errors.Is(err, pgx.ErrNoRows) {
		return Status{}, ErrNotFound
	}
	if err != nil {
		return Status{}, err
	}
	if status != "requested" || time.Since(created) > gestureTTL {
		return Status{}, ErrState
	}
	key := "verify/" + userID + "/" + id + ".jpg"
	if err := s.Store.Put(ctx, key, jpg); err != nil {
		return Status{}, err
	}
	if _, err := tx.Exec(ctx, `UPDATE photo_verifications SET status = 'pending', object_key = $2, submitted_at = now()
		WHERE id = $1`, id, key); err != nil {
		return Status{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		_ = s.Store.Delete(context.WithoutCancel(ctx), key)
		return Status{}, err
	}
	return Status{Status: "pending", ID: id}, nil
}

// Item — селфи в очереди модератора.
type Item struct {
	ID          string    `json:"id"`
	UserID      string    `json:"user_id"`
	Name        string    `json:"name"`
	Age         int       `json:"age"`
	Gesture     string    `json:"gesture"`
	SubmittedAt time.Time `json:"submitted_at"`
	// Photos — фото анкеты, с которыми сравнивать (GET /admin/api/photos/{id}).
	Photos []string `json:"photos"`
}

// Queue — ждут решения, старые первыми.
func (s *Service) Queue(ctx context.Context) ([]Item, error) {
	rows, err := s.DB.Query(ctx, `
		SELECT v.id, v.user_id, coalesce(p.display_name, ''), date_part('year', age(u.birth_date))::int, v.gesture, v.submitted_at
		FROM photo_verifications v
		JOIN users u ON u.id = v.user_id
		LEFT JOIN profiles p ON p.user_id = v.user_id
		WHERE v.status = 'pending'
		ORDER BY v.submitted_at
		LIMIT 100`)
	if err != nil {
		return nil, err
	}
	items, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Item, error) {
		var it Item
		var g string
		err := r.Scan(&it.ID, &it.UserID, &it.Name, &it.Age, &g, &it.SubmittedAt)
		it.Gesture = gestureText(g)
		return it, err
	})
	if err != nil {
		return nil, err
	}
	ids := make([]string, len(items))
	for i, it := range items {
		ids[i] = it.UserID
	}
	ph, err := photos.IDs(ctx, s.DB, ids)
	if err != nil {
		return nil, err
	}
	for i := range items {
		items[i].Photos = ph[items[i].UserID]
		if items[i].Photos == nil {
			items[i].Photos = []string{}
		}
	}
	if items == nil {
		items = []Item{}
	}
	return items, nil
}

// Selfie — файл селфи для модератора.
func (s *Service) Selfie(ctx context.Context, id string) ([]byte, error) {
	var key string
	err := s.DB.QueryRow(ctx, `SELECT object_key FROM photo_verifications WHERE id = $1 AND status = 'pending'`, id).Scan(&key)
	if errors.Is(err, pgx.ErrNoRows) || key == "" {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return s.Store.Get(ctx, key)
}

// Decide — решение модератора. Селфи после него удаляется. Возвращает, чьё это селфи.
func (s *Service) Decide(ctx context.Context, id, moderator string, approve bool, note string) (string, error) {
	userID, err := s.decide(ctx, id, moderator, approve, note)
	return userID, err
}

func (s *Service) decide(ctx context.Context, id, moderator string, approve bool, note string) (userID string, err error) {
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return "", err
	}
	defer tx.Rollback(ctx)
	var key string
	err = tx.QueryRow(ctx, `SELECT user_id, object_key FROM photo_verifications WHERE id = $1 AND status = 'pending' FOR UPDATE`,
		id).Scan(&userID, &key)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", err
	}
	status, action := "rejected", "reject_photo"
	if approve {
		status, action, note = "approved", "verify_photo", ""
		if _, err := tx.Exec(ctx, `UPDATE users SET photo_verified_at = now() WHERE id = $1`, userID); err != nil {
			return "", err
		}
	} else if note == "" {
		note = Reasons[0]
	}
	if _, err := tx.Exec(ctx, `UPDATE photo_verifications SET status = $2, note = $3, moderator = $4, decided_at = now(),
		object_key = '' WHERE id = $1`, id, status, note, moderator); err != nil {
		return "", err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO moderation_actions (target, action, moderator, note) VALUES ($1, $2, $3, $4)`,
		userID, action, moderator, note); err != nil {
		return "", err
	}
	if err := tx.Commit(ctx); err != nil {
		return "", err
	}
	return userID, s.Store.Delete(ctx, key)
}
