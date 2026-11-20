// Package photos — фото анкеты: загрузка, порядок, удаление и доступ.
//
// Каждое фото перекодируется в JPEG: так выбрасываются метаданные (в них бывает
// GPS и модель телефона), а поворот из EXIF применяется к самим пикселям.
// Кто может смотреть фото, решает Open — те же правила, что в ленте.
package photos

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"image"
	"image/jpeg"
	_ "image/png" // принимаем PNG (скриншоты, редакторы)
	"os"
	"path/filepath"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	xdraw "golang.org/x/image/draw"
	_ "golang.org/x/image/webp" // и WebP

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/limits"
)

const (
	// MaxPhotos — сколько фото в анкете.
	MaxPhotos = 6
	// MaxUploadBytes — предел исходного файла.
	MaxUploadBytes = 15 << 20
	// MaxSide — длинная сторона после уменьшения: чётко на любом телефоне, без лишнего веса.
	MaxSide = 1600
	// maxPixels — защита от «картинки-бомбы»: огромные размеры при маленьком файле.
	maxPixels = 50_000_000
	quality   = 85
)

var (
	ErrNotFound = errors.New("фото не найдено")
	ErrTooMany  = &Error{fmt.Sprintf("В анкете может быть до %d фото — удалите какое-нибудь, чтобы добавить новое.", MaxPhotos)}
	ErrBadImage = &Error{"Не получилось открыть картинку. Подойдут фото в JPEG, PNG или WebP."}
	ErrTooBig   = &Error{"Файл слишком большой — до 15 МБ."}
	ErrBadOrder = &Error{"Порядок фото не совпадает с анкетой — обновите экран."}
)

// Error — ошибка, которую можно показать человеку как есть.
type Error struct{ Message string }

func (e *Error) Error() string { return e.Message }

// Store — где лежат файлы. Пока папка на диске, потом — объектное хранилище.
type Store interface {
	Put(ctx context.Context, key string, data []byte) error
	Get(ctx context.Context, key string) ([]byte, error)
	Delete(ctx context.Context, key string) error
}

// DiskStore — файлы в папке на сервере.
type DiskStore struct{ Dir string }

func (d DiskStore) path(key string) (string, error) {
	// Ключи составляем сами (uuid/uuid.jpg), но на всякий случай не выпускаем за пределы папки.
	clean := filepath.Clean(key)
	if filepath.IsAbs(clean) || strings.HasPrefix(clean, "..") {
		return "", fmt.Errorf("photos: недопустимый ключ %q", key)
	}
	return filepath.Join(d.Dir, clean), nil
}

func (d DiskStore) Put(_ context.Context, key string, data []byte) error {
	p, err := d.path(key)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o750); err != nil {
		return err
	}
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, data, 0o640); err != nil {
		return err
	}
	return os.Rename(tmp, p)
}

func (d DiskStore) Get(_ context.Context, key string) ([]byte, error) {
	p, err := d.path(key)
	if err != nil {
		return nil, err
	}
	b, err := os.ReadFile(p)
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrNotFound
	}
	return b, err
}

func (d DiskStore) Delete(_ context.Context, key string) error {
	p, err := d.path(key)
	if err != nil {
		return err
	}
	if err := os.Remove(p); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

// Service — фото анкеты.
type Service struct {
	DB    *pgxpool.Pool
	Store Store
}

// Photo — фото в анкете.
type Photo struct {
	ID       string `json:"id"`
	Position int    `json:"position"`
}

// List — свои фото по порядку; первое — главное.
func (s *Service) List(ctx context.Context, userID string) ([]Photo, error) {
	rows, err := s.DB.Query(ctx, `SELECT id, position FROM photos WHERE user_id = $1 ORDER BY position, created_at`, userID)
	if err != nil {
		return nil, err
	}
	out, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (Photo, error) {
		var p Photo
		return p, r.Scan(&p.ID, &p.Position)
	})
	if out == nil {
		out = []Photo{}
	}
	return out, err
}

// IDs — фото нескольких людей по порядку (для ленты и чата). Кто может их смотреть,
// вызывающий решает сам; Open всё равно проверит при загрузке.
func IDs(ctx context.Context, db interface {
	Query(context.Context, string, ...any) (pgx.Rows, error)
}, userIDs []string) (map[string][]string, error) {
	out := map[string][]string{}
	if len(userIDs) == 0 {
		return out, nil
	}
	rows, err := db.Query(ctx, `SELECT user_id, id FROM photos WHERE user_id = ANY($1::uuid[]) AND moderation <> 'rejected'
		ORDER BY user_id, position, created_at`, userIDs)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var u, id string
		if err := rows.Scan(&u, &id); err != nil {
			return nil, err
		}
		out[u] = append(out[u], id)
	}
	return out, rows.Err()
}

// Prepare декодирует картинку, поворачивает по EXIF, уменьшает и перекодирует в JPEG без метаданных.
func Prepare(data []byte) ([]byte, error) {
	if len(data) > MaxUploadBytes {
		return nil, ErrTooBig
	}
	cfg, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil || cfg.Width < 1 || cfg.Height < 1 || cfg.Width*cfg.Height > maxPixels {
		return nil, ErrBadImage
	}
	img, _, err := image.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, ErrBadImage
	}
	img = orient(img, orientation(data))
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	if w > MaxSide || h > MaxSide {
		if w >= h {
			w, h = MaxSide, max(1, h*MaxSide/b.Dx())
		} else {
			w, h = max(1, w*MaxSide/b.Dy()), MaxSide
		}
	}
	dst := image.NewRGBA(image.Rect(0, 0, w, h))
	// Белый фон под прозрачные PNG, иначе в JPEG они станут чёрными.
	xdraw.Draw(dst, dst.Bounds(), image.White, image.Point{}, xdraw.Src)
	xdraw.CatmullRom.Scale(dst, dst.Bounds(), img, b, xdraw.Over, nil)
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, dst, &jpeg.Options{Quality: quality}); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// Upload добавляет фото в конец анкеты.
func (s *Service) Upload(ctx context.Context, userID string, data []byte) (Photo, error) {
	jpg, err := Prepare(data)
	if err != nil {
		return Photo{}, err
	}
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return Photo{}, err
	}
	defer tx.Rollback(ctx)
	// Блокируем человека: две загрузки сразу не превысят предел.
	if _, err := tx.Exec(ctx, `SELECT 1 FROM users WHERE id = $1 FOR UPDATE`, userID); err != nil {
		return Photo{}, err
	}
	var count int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM photos WHERE user_id = $1`, userID).Scan(&count); err != nil {
		return Photo{}, err
	}
	if count >= MaxPhotos {
		return Photo{}, ErrTooMany
	}
	// Удалённые фото тоже считаются, поэтому загрузки пишем в отдельный журнал.
	var uploads int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM photo_uploads WHERE user_id = $1 AND created_at > now() - interval '24 hours'`,
		userID).Scan(&uploads); err != nil {
		return Photo{}, err
	}
	if uploads >= limits.PhotosPerDay {
		return Photo{}, limits.ErrPhotos
	}
	var p Photo
	p.Position = count
	if err := tx.QueryRow(ctx, `INSERT INTO photos (user_id, object_key, position) VALUES ($1, '', $2) RETURNING id`,
		userID, p.Position).Scan(&p.ID); err != nil {
		return Photo{}, err
	}
	key := userID + "/" + p.ID + ".jpg"
	if _, err := tx.Exec(ctx, `UPDATE photos SET object_key = $2 WHERE id = $1`, p.ID, key); err != nil {
		return Photo{}, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO photo_uploads (user_id) VALUES ($1)`, userID); err != nil {
		return Photo{}, err
	}
	if err := s.Store.Put(ctx, key, jpg); err != nil {
		return Photo{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		_ = s.Store.Delete(context.WithoutCancel(ctx), key)
		return Photo{}, err
	}
	return p, nil
}

// Delete убирает своё фото; остальные сдвигаются.
func (s *Service) Delete(ctx context.Context, userID, photoID string) error {
	key, err := s.remove(ctx, photoID, userID)
	if err != nil {
		return err
	}
	return s.Store.Delete(ctx, key)
}

// Remove — модератор убирает фото. Возвращает владельца.
func (s *Service) Remove(ctx context.Context, photoID string) (string, error) {
	var owner string
	if err := s.DB.QueryRow(ctx, `SELECT user_id FROM photos WHERE id = $1`, photoID).Scan(&owner); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return "", ErrNotFound
		}
		return "", err
	}
	key, err := s.remove(ctx, photoID, owner)
	if err != nil {
		return "", err
	}
	return owner, s.Store.Delete(ctx, key)
}

func (s *Service) remove(ctx context.Context, photoID, userID string) (string, error) {
	if !validUUID(photoID) {
		return "", ErrNotFound
	}
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return "", err
	}
	defer tx.Rollback(ctx)
	var key string
	err = tx.QueryRow(ctx, `DELETE FROM photos WHERE id = $1 AND user_id = $2 RETURNING object_key`, photoID, userID).Scan(&key)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", err
	}
	if _, err := tx.Exec(ctx, `UPDATE photos p SET position = o.n - 1
		FROM (SELECT id, row_number() OVER (ORDER BY position, created_at) AS n FROM photos WHERE user_id = $1) o
		WHERE p.id = o.id`, userID); err != nil {
		return "", err
	}
	// Проверка по селфи подтверждает, что фото анкеты — твои. Удалили все фото — значок снимается.
	if _, err := tx.Exec(ctx, `UPDATE users SET photo_verified_at = NULL
		WHERE id = $1 AND NOT EXISTS (SELECT 1 FROM photos WHERE user_id = $1)`, userID); err != nil {
		return "", err
	}
	return key, tx.Commit(ctx)
}

// Reorder задаёт порядок: ids — все фото анкеты, первое станет главным.
func (s *Service) Reorder(ctx context.Context, userID string, ids []string) error {
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	rows, err := tx.Query(ctx, `SELECT id FROM photos WHERE user_id = $1 FOR UPDATE`, userID)
	if err != nil {
		return err
	}
	have, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return err
	}
	if len(have) != len(ids) {
		return ErrBadOrder
	}
	set := map[string]bool{}
	for _, id := range have {
		set[id] = true
	}
	for i, id := range ids {
		if !set[id] {
			return ErrBadOrder
		}
		delete(set, id)
		if _, err := tx.Exec(ctx, `UPDATE photos SET position = $3 WHERE id = $1 AND user_id = $2`, id, userID, i); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

// Open отдаёт фото, если смотрящему можно его видеть:
// своё; собеседника по активному совпадению; иначе — если ни владелец, ни
// смотрящий не прячут фото до взаимности, никто никого не заблокировал
// и владелец не скрыт модератором.
func (s *Service) Open(ctx context.Context, viewerID, photoID string, visibleUserSQL string) ([]byte, error) {
	if !validUUID(photoID) {
		return nil, ErrNotFound
	}
	var key, owner string
	err := s.DB.QueryRow(ctx, `SELECT object_key, user_id FROM photos WHERE id = $1 AND moderation <> 'rejected'`, photoID).Scan(&key, &owner)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if owner != viewerID {
		var ok bool
		err := s.DB.QueryRow(ctx, `
			SELECT EXISTS (SELECT 1 FROM users u WHERE u.id = $2 AND `+visibleUserSQL+`)
			   AND NOT EXISTS (SELECT 1 FROM blocks WHERE (blocker = $1 AND blocked = $2) OR (blocker = $2 AND blocked = $1))
			   AND (EXISTS (SELECT 1 FROM matches WHERE ended_at IS NULL
			                AND user_a = least($1::uuid, $2::uuid) AND user_b = greatest($1::uuid, $2::uuid))
			        OR NOT EXISTS (SELECT 1 FROM profile_field_visibility
			                       WHERE user_id IN ($1, $2) AND field = 'photos' AND visibility <> 'anonymous'))`,
			viewerID, owner).Scan(&ok)
		if err != nil {
			return nil, err
		}
		if !ok {
			return nil, ErrNotFound
		}
	}
	return s.Store.Get(ctx, key)
}

// Raw — фото без проверки доступа: только для модератора.
func (s *Service) Raw(ctx context.Context, photoID string) ([]byte, error) {
	if !validUUID(photoID) {
		return nil, ErrNotFound
	}
	var key string
	err := s.DB.QueryRow(ctx, `SELECT object_key FROM photos WHERE id = $1`, photoID).Scan(&key)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return s.Store.Get(ctx, key)
}

func validUUID(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i, c := range s {
		switch {
		case i == 8 || i == 13 || i == 18 || i == 23:
			if c != '-' {
				return false
			}
		case (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'):
		default:
			return false
		}
	}
	return true
}
