package httpapi

import (
	"crypto/subtle"
	"embed"
	"errors"
	"io/fs"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/moderation"
)

//go:embed admin/*
var adminFiles embed.FS

// registerAdmin — страница модератора /admin и её API. Включается, только если задан
// ADMIN_TOKEN: без него ни страницы, ни API нет.
func (s *Server) registerAdmin(mux *http.ServeMux) {
	static, _ := fs.Sub(adminFiles, "admin")
	files := http.StripPrefix("/admin/", http.FileServer(http.FS(static)))
	page := func(w http.ResponseWriter, r *http.Request) {
		// Страница без внешних скриптов и стилей; не открывается во фрейме; не кэшируется.
		w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Robots-Tag", "noindex")
		if r.URL.Path == "/admin" {
			http.Redirect(w, r, "/admin/", http.StatusMovedPermanently)
			return
		}
		files.ServeHTTP(w, r)
	}
	mux.HandleFunc("GET /admin", page)
	mux.HandleFunc("GET /admin/{file...}", page)

	h := func(pattern string, fn http.HandlerFunc) { mux.Handle(pattern, s.withAdmin(fn)) }
	h("GET /admin/api/stats", func(w http.ResponseWriter, r *http.Request) {
		st, err := s.moderation.Stats(r.Context())
		s.adminRespond(w, st, err)
	})
	h("GET /admin/api/reports", func(w http.ResponseWriter, r *http.Request) {
		items, err := s.moderation.Queue(r.Context(), r.URL.Query().Get("status"), 100)
		s.adminRespond(w, map[string]any{"items": items}, err)
	})
	h("GET /admin/api/reports/{id}", func(w http.ResponseWriter, r *http.Request) {
		id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
		d, err := s.moderation.Get(r.Context(), id)
		s.adminRespond(w, d, err)
	})
	h("POST /admin/api/reports/{id}/resolve", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Action string `json:"action"`
			Days   int    `json:"days"`
			Note   string `json:"note"`
		}
		if !decode(w, r, &req) {
			return
		}
		id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
		err := s.moderation.Resolve(r.Context(), id, moderator(r), req.Action, req.Days, req.Note)
		s.adminRespond(w, nil, err)
	})
	h("POST /admin/api/users/{id}/unban", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Note string `json:"note"`
		}
		if !decode(w, r, &req) {
			return
		}
		s.adminRespond(w, nil, s.moderation.Unban(r.Context(), r.PathValue("id"), moderator(r), req.Note))
	})
}

// withAdmin пропускает только с ключом модератора. Неверный ключ — пауза, чтобы его нельзя было подбирать.
func (s *Server) withAdmin(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		got := bearer(r)
		if got == "" || subtle.ConstantTimeCompare([]byte(got), []byte(s.adminToken)) != 1 {
			time.Sleep(500 * time.Millisecond)
			writeError(w, http.StatusUnauthorized, "неверный ключ модератора")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// moderator — имя модератора для журнала решений (из заголовка, его задаёт страница).
// Страница кодирует имя (кириллица в заголовках не допускается).
func moderator(r *http.Request) string {
	raw := r.Header.Get("X-Moderator")
	if v, err := url.QueryUnescape(raw); err == nil {
		raw = v
	}
	return strings.TrimSpace(raw)
}

func (s *Server) adminRespond(w http.ResponseWriter, v any, err error) {
	switch {
	case err == nil && v == nil:
		w.WriteHeader(http.StatusNoContent)
	case err == nil:
		writeJSON(w, http.StatusOK, v)
	case errors.Is(err, moderation.ErrNotFound), errors.Is(err, moderation.ErrUserNotFound):
		writeError(w, http.StatusNotFound, err.Error())
	case errors.Is(err, moderation.ErrAlreadyClosed):
		writeError(w, http.StatusConflict, err.Error())
	case errors.Is(err, moderation.ErrBadAction), errors.Is(err, moderation.ErrBadDays):
		writeError(w, http.StatusBadRequest, err.Error())
	default:
		s.log.Error("ошибка модерации", "err", err)
		writeError(w, http.StatusInternalServerError, "что-то пошло не так")
	}
}
