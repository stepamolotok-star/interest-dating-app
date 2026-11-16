package feed

import (
	"bytes"
	"context"
	"errors"
	"image"
	"image/jpeg"
	"testing"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/limits"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/matching"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/photos"
)

func tinyJPEG(t *testing.T) []byte {
	t.Helper()
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, image.NewRGBA(image.Rect(0, 0, 30, 40)), nil); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// Фото: предел в анкете и за сутки, порядок, удаление, кто может смотреть, фото в ленте.
func TestPhotos(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	ph := &photos.Service{DB: e.db, Store: photos.DiskStore{Dir: t.TempDir()}}
	anna := e.user(t, person{goals: []matching.Goal{matching.Hobby}, interests: []string{enduro}})
	igor := e.user(t, person{gender: "male", goals: []matching.Goal{matching.Hobby}, interests: []string{enduro}})
	oleg := e.user(t, person{gender: "male", goals: []matching.Goal{matching.Hobby}, interests: []string{enduro}})

	var ids []string
	for i := 0; i < photos.MaxPhotos; i++ {
		p, err := ph.Upload(ctx, anna, tinyJPEG(t))
		if err != nil {
			t.Fatal(err)
		}
		if p.Position != i {
			t.Fatalf("позиция %d, ждали %d", p.Position, i)
		}
		ids = append(ids, p.ID)
	}
	if _, err := ph.Upload(ctx, anna, tinyJPEG(t)); !errors.Is(err, photos.ErrTooMany) {
		t.Fatalf("седьмое фото: %v", err)
	}

	// Удаление сдвигает остальные, порядок можно поменять.
	if err := ph.Delete(ctx, anna, ids[0]); err != nil {
		t.Fatal(err)
	}
	if err := ph.Delete(ctx, igor, ids[1]); !errors.Is(err, photos.ErrNotFound) {
		t.Fatalf("чужое фото удалять нельзя: %v", err)
	}
	list, _ := ph.List(ctx, anna)
	if len(list) != 5 || list[0].ID != ids[1] || list[4].Position != 4 {
		t.Fatalf("после удаления: %+v", list)
	}
	order := []string{ids[5], ids[1], ids[2], ids[3], ids[4]}
	if err := ph.Reorder(ctx, anna, order); err != nil {
		t.Fatal(err)
	}
	if err := ph.Reorder(ctx, anna, order[:3]); !errors.Is(err, photos.ErrBadOrder) {
		t.Fatalf("неполный порядок: %v", err)
	}
	list, _ = ph.List(ctx, anna)
	if list[0].ID != ids[5] {
		t.Fatalf("главное фото: %+v", list)
	}

	// Лента: Игорь видит фото Анны по порядку.
	cards, err := e.feed.Feed(ctx, igor, matching.Hobby, 10)
	if err != nil {
		t.Fatal(err)
	}
	var annaCard *Card
	for i := range cards {
		if cards[i].UserID == anna {
			annaCard = &cards[i]
		}
	}
	if annaCard == nil || len(annaCard.Photos) != 5 || annaCard.Photos[0] != ids[5] {
		t.Fatalf("карточка Анны: %+v", annaCard)
	}
	if _, err := ph.Open(ctx, igor, ids[5], VisibleUserSQL); err != nil {
		t.Fatalf("Игорь должен видеть фото: %v", err)
	}

	// Анна прячет фото до взаимности: ни в ленте, ни по ссылке.
	if err := e.prof.SetVisibility(ctx, anna, map[string]string{"photos": "after_match"}); err != nil {
		t.Fatal(err)
	}
	cards, _ = e.feed.Feed(ctx, igor, matching.Hobby, 10)
	for _, c := range cards {
		if c.UserID == anna && (len(c.Photos) != 0 || !c.PhotosHidden) {
			t.Fatalf("фото должны быть скрыты: %+v", c)
		}
	}
	if _, err := ph.Open(ctx, igor, ids[5], VisibleUserSQL); !errors.Is(err, photos.ErrNotFound) {
		t.Fatalf("скрытое фото по ссылке: %v", err)
	}
	// После совпадения — видно.
	if _, err := e.feed.Interest(ctx, igor, anna, matching.Hobby, ""); err != nil {
		t.Fatal(err)
	}
	if _, err := e.feed.Interest(ctx, anna, igor, matching.Hobby, ""); err != nil {
		t.Fatal(err)
	}
	if _, err := ph.Open(ctx, igor, ids[5], VisibleUserSQL); err != nil {
		t.Fatalf("после совпадения фото видно: %v", err)
	}
	// Олег не совпал — не видит; заблокированный не видит даже при открытых фото.
	if _, err := ph.Open(ctx, oleg, ids[5], VisibleUserSQL); !errors.Is(err, photos.ErrNotFound) {
		t.Fatalf("Олег не должен видеть: %v", err)
	}
	if err := e.prof.SetVisibility(ctx, anna, map[string]string{"photos": "anonymous"}); err != nil {
		t.Fatal(err)
	}
	if _, err := ph.Open(ctx, oleg, ids[5], VisibleUserSQL); err != nil {
		t.Fatalf("открытые фото Олег видит: %v", err)
	}
	if _, err := e.db.Exec(ctx, `INSERT INTO blocks (blocker, blocked) VALUES ($1, $2)`, anna, oleg); err != nil {
		t.Fatal(err)
	}
	if _, err := ph.Open(ctx, oleg, ids[5], VisibleUserSQL); !errors.Is(err, photos.ErrNotFound) {
		t.Fatalf("заблокированный видит фото: %v", err)
	}
	// Модератор убрал фото — его нет ни у кого.
	owner, err := ph.Remove(ctx, ids[5])
	if err != nil || owner != anna {
		t.Fatalf("Remove: %s %v", owner, err)
	}
	if _, err := ph.Open(ctx, anna, ids[5], VisibleUserSQL); !errors.Is(err, photos.ErrNotFound) {
		t.Fatalf("убранное фото: %v", err)
	}

	// Предел загрузок за сутки считает и удалённые.
	if _, err := e.db.Exec(ctx, `INSERT INTO photo_uploads (user_id) SELECT $1 FROM generate_series(1, $2)`,
		oleg, limits.PhotosPerDay); err != nil {
		t.Fatal(err)
	}
	if _, err := ph.Upload(ctx, oleg, tinyJPEG(t)); !errors.Is(err, limits.ErrPhotos) {
		t.Fatalf("предел за сутки: %v", err)
	}
}
