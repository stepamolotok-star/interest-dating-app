package httpapi

import (
	"errors"
	"net/http"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/notify"
)

func (s *Server) registerNotify(mux *http.ServeMux) {
	h := func(pattern string, fn http.HandlerFunc) { mux.Handle(pattern, s.withUser(fn)) }
	h("PUT /v1/me/push-token", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Token    string `json:"token"`
			Provider string `json:"provider"`
		}
		if !decode(w, r, &req) {
			return
		}
		err := s.notify.SetToken(r.Context(), uid(r), req.Token, req.Provider)
		if errors.Is(err, notify.ErrBadToken) {
			writeError(w, http.StatusBadRequest, "неверный токен устройства")
			return
		}
		s.respond(w, nil, err)
	})
	h("DELETE /v1/me/push-token", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Token string `json:"token"`
		}
		if !decode(w, r, &req) {
			return
		}
		s.respond(w, nil, s.notify.DeleteToken(r.Context(), uid(r), req.Token))
	})
	h("GET /v1/me/notifications", func(w http.ResponseWriter, r *http.Request) {
		st, err := s.notify.Get(r.Context(), uid(r))
		s.respond(w, st, err)
	})
	h("PUT /v1/me/notifications", func(w http.ResponseWriter, r *http.Request) {
		var st notify.Settings
		if !decode(w, r, &st) {
			return
		}
		s.respond(w, nil, s.notify.Set(r.Context(), uid(r), st))
	})
}
