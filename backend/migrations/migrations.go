// Package migrations встраивает SQL-миграции в бинарник и применяет их по порядку.
package migrations

import (
	"context"
	"embed"
	"fmt"
	"io/fs"
	"sort"

	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed *.sql
var files embed.FS

// Apply применяет ещё не применённые миграции, каждую в своей транзакции.
func Apply(ctx context.Context, db *pgxpool.Pool) ([]string, error) {
	if _, err := db.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())`); err != nil {
		return nil, fmt.Errorf("migrations: таблица учёта: %w", err)
	}
	names, err := fs.Glob(files, "*.sql")
	if err != nil {
		return nil, err
	}
	sort.Strings(names)
	var applied []string
	for _, name := range names {
		var done bool
		if err := db.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE name = $1)`, name).Scan(&done); err != nil {
			return applied, err
		}
		if done {
			continue
		}
		sql, err := files.ReadFile(name)
		if err != nil {
			return applied, err
		}
		tx, err := db.Begin(ctx)
		if err != nil {
			return applied, err
		}
		if _, err := tx.Exec(ctx, string(sql)); err != nil {
			_ = tx.Rollback(ctx)
			return applied, fmt.Errorf("migrations: %s: %w", name, err)
		}
		if _, err := tx.Exec(ctx, `INSERT INTO schema_migrations (name) VALUES ($1)`, name); err != nil {
			_ = tx.Rollback(ctx)
			return applied, err
		}
		if err := tx.Commit(ctx); err != nil {
			return applied, err
		}
		applied = append(applied, name)
	}
	return applied, nil
}
