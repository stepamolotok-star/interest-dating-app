// Package account — удаление аккаунта (это же — отзыв согласия на обработку ПДн).
//
// Удаляется всё сразу и целиком: анкета, фото, переписки, совпадения, жалобы,
// согласия, сессии. Остаётся только отпечаток номера в banned_phones, если аккаунт
// был заблокирован навсегда, — чтобы с него нельзя было вернуться.
package account

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/photos"
)

// Hider убирает человека из «Рядом» (геопозиция хранится отдельно от базы).
type Hider interface {
	Disappear(ctx context.Context, userID string) error
}

// Service — удаление аккаунта.
type Service struct {
	DB     *pgxpool.Pool
	Store  photos.Store
	Nearby Hider // nil — «Рядом» выключен
}

// ErrNotFound — аккаунта уже нет.
var ErrNotFound = errors.New("аккаунт не найден")

// Delete удаляет аккаунт и все файлы человека.
func (s *Service) Delete(ctx context.Context, userID string) error {
	if s.Nearby != nil {
		// Сначала исчезаем из «Рядом»: после удаления из базы некому будет это сделать.
		if err := s.Nearby.Disappear(ctx, userID); err != nil {
			return err
		}
	}
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	rows, err := tx.Query(ctx, `
		SELECT object_key FROM photos WHERE user_id = $1 AND object_key <> ''
		UNION ALL
		SELECT object_key FROM photo_verifications WHERE user_id = $1 AND object_key <> ''`, userID)
	if err != nil {
		return err
	}
	keys, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return err
	}
	var phone string
	err = tx.QueryRow(ctx, `DELETE FROM users WHERE id = $1 RETURNING phone_e164`, userID).Scan(&phone)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	// Номер остаётся в сессиях и попытках входа — их тоже удаляем.
	if _, err := tx.Exec(ctx, `DELETE FROM sessions WHERE phone_e164 = $1`, phone); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM auth_attempts WHERE phone_e164 = $1`, phone); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	var firstErr error
	for _, k := range keys {
		if err := s.Store.Delete(ctx, k); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}
