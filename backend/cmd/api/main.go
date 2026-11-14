// Команда api запускает HTTP-сервер приложения.
//
// Переменные окружения:
//
//	PORT          порт (по умолчанию 8080)
//	APP_ENV       dev | prod (по умолчанию dev)
//	DATABASE_URL  строка подключения к PostgreSQL; без неё вход отключён
//	AUTH_SECRET   ключ HMAC для кодов входа; в prod обязателен
//	REDIS_URL     адрес Redis (redis://localhost:6379/0); без него «Рядом» отключён
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/auth"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/catalog"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/chat"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/cities"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/contacts"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/feed"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/httpapi"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/moderation"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/nearby"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/oauth"
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
	cityCat, err := cities.Default()
	if err != nil {
		return fmt.Errorf("справочник городов: %w", err)
	}
	deps := httpapi.Deps{Catalog: cat, Cities: cityCat, Log: log}

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
		deps.Chat = &chat.Service{DB: db, Catalog: cat}

		if rurl := os.Getenv("REDIS_URL"); rurl != "" {
			opt, err := redis.ParseURL(rurl)
			if err != nil {
				return err
			}
			rdb := redis.NewClient(opt)
			defer rdb.Close()
			nb := &nearby.Service{DB: db, Redis: rdb, Feed: deps.Feed, Push: nearby.LogPusher{Log: log}}
			deps.Nearby = nb
			go notifyLoop(ctx, nb, log)
		} else {
			log.Warn("REDIS_URL не задан — режим «Рядом» отключён")
		}

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
		deps.Auth = &auth.Service{DB: db, Caller: dev, SMS: dev, Secret: []byte(secret), Cities: deps.Cities}
		// Отдельный секрет: AUTH_SECRET можно менять, а ключи контактов без исходных хэшей не пересчитать.
		contactsSecret := envOr("CONTACTS_SECRET", secret)
		deps.Auth.ContactsSecret = []byte(contactsSecret)
		deps.Contacts = &contacts.Service{DB: db, Secret: []byte(contactsSecret)}
		deps.OAuth = &oauth.Service{DB: db, Providers: oauthProviders()}
		deps.Moderation = &moderation.Service{DB: db, PhoneSecret: []byte(contactsSecret)}
		if deps.Nearby != nil {
			deps.Moderation.Nearby = deps.Nearby
		}
		// Страница модератора /admin — только с длинным случайным ключом.
		if t := os.Getenv("ADMIN_TOKEN"); len(t) >= 24 {
			deps.AdminToken = t
		} else if t != "" {
			log.Warn("ADMIN_TOKEN короче 24 символов — страница модератора отключена")
		}
		if n, err := deps.Auth.BackfillCities(ctx); err != nil {
			return err
		} else if n > 0 {
			log.Info("города переведены на справочник", "profiles", n)
		}
		if n, err := deps.Contacts.Backfill(ctx); err != nil {
			return err
		} else if n > 0 {
			log.Info("досчитаны ключи номеров", "users", n)
		}
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

// notifyLoop раз в минуту рассылает уведомления о подходящих людях рядом.
func notifyLoop(ctx context.Context, nb *nearby.Service, log *slog.Logger) {
	t := time.NewTicker(time.Minute)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if n, err := nb.RunNotifications(ctx); err != nil {
				log.Error("уведомления «Рядом»", "err", err)
			} else if n > 0 {
				log.Info("уведомления «Рядом» отправлены", "count", n)
			}
		}
	}
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// oauthProviders — способы входа, для которых заданы ключи. Без ключей кнопки не показываются.
func oauthProviders() []oauth.Provider {
	var out []oauth.Provider
	if id := os.Getenv("VKID_CLIENT_ID"); id != "" {
		out = append(out, oauth.VKID{ClientID: id, Redirect: envOr("VKID_REDIRECT_URI", "vk"+id+"://vk.ru/blank.html")})
	}
	if id := os.Getenv("YANDEX_CLIENT_ID"); id != "" {
		out = append(out, oauth.YandexID{ClientID: id, Redirect: envOr("YANDEX_REDIRECT_URI", "ru.svoi://oauth/yandex")})
	}
	return out
}
