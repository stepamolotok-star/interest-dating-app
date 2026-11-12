// Package httpapi — HTTP-слой сервера: каталог, вход, профиль и лента.
package httpapi

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/auth"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/catalog"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/chat"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/feed"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/nearby"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/profile"
)

// Deps — зависимости HTTP-слоя. Auth может быть nil (тогда вход, профиль
// и лента отключены).
type Deps struct {
	Catalog *catalog.Catalog
	Auth    *auth.Service
	Profile *profile.Service
	Feed    *feed.Service
	Chat    *chat.Service
	Nearby  *nearby.Service
	Log     *slog.Logger
}

// Server собирает обработчики.
type Server struct {
	cat     *catalog.Catalog
	auth    *auth.Service
	profile *profile.Service
	feed    *feed.Service
	chat    *chat.Service
	nearby  *nearby.Service
	log     *slog.Logger
}

// New возвращает готовый http.Handler.
func New(d Deps) http.Handler {
	s := &Server{cat: d.Catalog, auth: d.Auth, profile: d.Profile, feed: d.Feed, chat: d.Chat, nearby: d.Nearby, log: d.Log}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.health)
	mux.HandleFunc("GET /v1/interests/categories", s.categories)
	mux.HandleFunc("GET /v1/interests/search", s.search)
	mux.HandleFunc("GET /v1/interests/{id}/children", s.children)
	if s.auth != nil {
		s.registerAuth(mux)
		if s.profile != nil {
			s.registerProfile(mux)
		}
		if s.nearby != nil {
			s.registerNearby(mux)
		}
	}
	return s.logging(mux)
}

type interestDTO struct {
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	Depth    int      `json:"depth"`
	Path     []string `json:"path,omitempty"`
	HasChild bool     `json:"has_children"`
}

func (s *Server) dto(n catalog.Node, withPath bool) interestDTO {
	d := interestDTO{ID: n.ID, Name: n.Name, Depth: n.Depth, HasChild: len(s.cat.Children(n.ID)) > 0}
	if withPath {
		d.Path = s.cat.Path(n.ID)
	}
	return d
}

func (s *Server) health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) categories(w http.ResponseWriter, _ *http.Request) {
	nodes := s.cat.Categories()
	out := make([]interestDTO, len(nodes))
	for i, n := range nodes {
		out[i] = s.dto(n, false)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": out})
}

func (s *Server) children(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if _, ok := s.cat.Get(id); !ok {
		writeError(w, http.StatusNotFound, "интерес не найден")
		return
	}
	nodes := s.cat.Children(id)
	out := make([]interestDTO, len(nodes))
	for i, n := range nodes {
		out[i] = s.dto(n, false)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": out})
}

func (s *Server) search(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query().Get("q")
	if len([]rune(catalog.Normalize(q))) < 2 {
		writeError(w, http.StatusBadRequest, "запрос должен быть не короче 2 символов")
		return
	}
	limit := 20
	if l, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && l > 0 && l <= 50 {
		limit = l
	}
	nodes := s.cat.Search(q, limit)
	out := make([]interestDTO, len(nodes))
	for i, n := range nodes {
		out[i] = s.dto(n, true)
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": out})
}

func (s *Server) logging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		// В лог не пишем query-параметры: в будущих запросах там могут быть личные данные.
		s.log.Info("request", "method", r.Method, "path", r.URL.Path, "duration", time.Since(start))
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}
