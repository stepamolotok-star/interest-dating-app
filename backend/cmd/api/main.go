// Команда api запускает HTTP-сервер приложения.
//
// Переменные окружения:
//
//	PORT          порт (по умолчанию 8080)
//	APP_ENV       dev | prod (по умолчанию dev)
//	DATABASE_URL  строка подключения к PostgreSQL; без неё вход отключён
//	AUTH_SECRET   ключ HMAC для кодов входа; в prod обязателен
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/auth"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/catalog"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/feed"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/httpapi"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/profile"
	"github.com/stepamolotok-star/interest-dating-app/backend/migrations"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	if err := run(log); err != nil {
		log.Error("сервер остановлен с ошибкой", "err", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	env := envOr("APP_ENV", "dev")
	cat, err := catalog.Default()
	if err != nil {
		return err
	}
	deps := httpapi.Deps{Catalog: cat, Log: log}

	if dsn := os.Getenv("DATABASE_URL"); dsn != "" {
		db, err := pgxpool.New(ctx, dsn)
		if err != nil {
			return err
		}
		defer db.Close()
		applied, err := migrations.Apply(ctx, db)
		if err != nil {
			return err
		}
		log.Info("миграции применены", "new", applied)
		prof := &profile.Service{DB: db, Catalog: cat}
		if err := prof.SyncCatalog(ctx); err != nil {
			return err
		}
		deps.Profile = prof
		deps.Feed = &feed.Service{DB: db, Catalog: cat}

		secret := os.Getenv("AUTH_SECRET")
		if secret == "" {
			if env == "prod" {
				return errors.New("AUTH_SECRET обязателен в prod")
			}
			secret = "dev-only-secret"
			log.Warn("AUTH_SECRET не задан — используется ключ для разработки")
		}
		if env == "prod" {
			// Поставщик звонков и SMS подключается здесь, когда будет договор.
			return errors.New("в prod не настроен поставщик звонков-сбросов и SMS")
		}
		dev := auth.DevProvider{Log: log}
		deps.Auth = &auth.Service{DB: db, Caller: dev, SMS: dev, Secret: []byte(secret)}
	} else {
		log.Warn("DATABASE_URL не задан — вход и регистрация отключены")
	}

	addr := ":" + envOr("PORT", "8080")
	srv := &http.Server{
		Addr:              addr,
		Handler:           httpapi.New(deps),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		log.Info("сервер запущен", "addr", addr, "env", env, "interests", cat.Len())
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
		close(errCh)
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
	}
	log.Info("останавливаю сервер")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return srv.Shutdown(shutdownCtx)
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
