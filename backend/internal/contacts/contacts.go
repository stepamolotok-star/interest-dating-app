// Package contacts — «скрыть меня от моих контактов».
//
// Приложение присылает SHA-256 от номеров из записной книжки (в формате +79XXXXXXXXX),
// сами номера и имена на сервер не уходят. На сервере хэш ещё раз прогоняется через
// HMAC с секретом: российских мобильных номеров всего около миллиарда, голый SHA-256
// перебирается за минуты, а HMAC без секрета — нет.
package contacts

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// MaxContacts — сколько номеров можно загрузить за раз.
const MaxContacts = 5000

// ValidationError — ошибка во входных данных.
type ValidationError struct{ Message string }

func (e *ValidationError) Error() string { return e.Message }

// Service хранит хэши контактов и настройку «скрыть от контактов».
type Service struct {
	DB     *pgxpool.Pool
	Secret []byte
}

// PhoneHash — то, что присылает приложение: SHA-256 номера в формате E.164.
func PhoneHash(phoneE164 string) []byte {
	h := sha256.Sum256([]byte(phoneE164))
	return h[:]
}

// Key — то, что хранится на сервере: HMAC(секрет, SHA-256 номера).
func Key(secret, phoneHash []byte) []byte {
	m := hmac.New(sha256.New, secret)
	m.Write(phoneHash)
	return m.Sum(nil)
}

// PhoneKey — ключ собственного номера пользователя.
func PhoneKey(secret []byte, phoneE164 string) []byte { return Key(secret, PhoneHash(phoneE164)) }

// Status — сколько номеров учтено и включено ли скрытие.
type Status struct {
	Count int  `json:"count"`
	Hide  bool `json:"hide"`
}

// Get возвращает состояние.
func (s *Service) Get(ctx context.Context, userID string) (Status, error) {
	var st Status
	err := s.DB.QueryRow(ctx, `
		SELECT (SELECT count(*) FROM contact_hashes WHERE user_id = $1),
		       coalesce((SELECT hide_from_contacts FROM visibility_settings WHERE user_id = $1), false)`,
		userID).Scan(&st.Count, &st.Hide)
	return st, err
}

// Upload заменяет список контактов и включает скрытие. hashes — hex SHA-256.
func (s *Service) Upload(ctx context.Context, userID string, hashes []string, docVersion string) (Status, error) {
	if len(hashes) > MaxContacts {
		return Status{}, &ValidationError{fmt.Sprintf("не больше %d номеров", MaxContacts)}
	}
	keys := make([][]byte, 0, len(hashes))
	seen := make(map[string]bool, len(hashes))
	for _, h := range hashes {
		raw, err := hex.DecodeString(h)
		if err != nil || len(raw) != sha256.Size {
			return Status{}, &ValidationError{"ожидаются SHA-256 в hex"}
		}
		if seen[h] {
			continue
		}
		seen[h] = true
		keys = append(keys, Key(s.Secret, raw))
	}
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return Status{}, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	if _, err := tx.Exec(ctx, `DELETE FROM contact_hashes WHERE user_id = $1`, userID); err != nil {
		return Status{}, err
	}
	if len(keys) > 0 {
		rows := make([][]any, len(keys))
		for i, k := range keys {
			rows[i] = []any{userID, k}
		}
		if _, err := tx.CopyFrom(ctx, pgx.Identifier{"contact_hashes"}, []string{"user_id", "phone_hash"},
			pgx.CopyFromRows(rows)); err != nil {
			return Status{}, err
		}
	}
	if _, err := tx.Exec(ctx, `INSERT INTO visibility_settings (user_id, hide_from_contacts) VALUES ($1, true)
		ON CONFLICT (user_id) DO UPDATE SET hide_from_contacts = true`, userID); err != nil {
		return Status{}, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO consents (user_id, kind, doc_version)
		SELECT $1, 'contacts', $2 WHERE NOT EXISTS (
			SELECT 1 FROM consents WHERE user_id = $1 AND kind = 'contacts' AND revoked_at IS NULL)`,
		userID, docVersion); err != nil {
		return Status{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Status{}, err
	}
	return Status{Count: len(keys), Hide: true}, nil
}

// Clear выключает скрытие, удаляет все хэши и отзывает согласие.
func (s *Service) Clear(ctx context.Context, userID string) error {
	tx, err := s.DB.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	for _, q := range []string{
		`DELETE FROM contact_hashes WHERE user_id = $1`,
		`UPDATE visibility_settings SET hide_from_contacts = false WHERE user_id = $1`,
		`UPDATE consents SET revoked_at = now() WHERE user_id = $1 AND kind = 'contacts' AND revoked_at IS NULL`,
	} {
		if _, err := tx.Exec(ctx, q, userID); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

// Backfill досчитывает ключи номеров пользователям, зарегистрированным до появления phone_key.
func (s *Service) Backfill(ctx context.Context) (int, error) {
	rows, err := s.DB.Query(ctx, `SELECT id, phone_e164 FROM users WHERE phone_key IS NULL`)
	if err != nil {
		return 0, err
	}
	type u struct{ id, phone string }
	list, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (u, error) {
		var x u
		return x, r.Scan(&x.id, &x.phone)
	})
	if err != nil {
		return 0, err
	}
	for _, x := range list {
		if _, err := s.DB.Exec(ctx, `UPDATE users SET phone_key = $2 WHERE id = $1`, x.id, PhoneKey(s.Secret, x.phone)); err != nil {
			return 0, err
		}
	}
	return len(list), nil
}
