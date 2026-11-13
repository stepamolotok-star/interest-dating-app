package httpapi

import (
	"errors"
	"net/http"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/oauth"
)

// Вход через VK ID и Яндекс ID: берём у провайдера только подтверждённый номер.
func (s *Server) registerOAuth(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/auth/providers", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"items": s.oauth.List()})
	})
	mux.HandleFunc("POST /v1/auth/oauth/{provider}/start", func(w http.ResponseWriter, r *http.Request) {
		st, err := s.oauth.Start(r.Context(), r.PathValue("provider"))
		if err != nil {
			s.oauthError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, st)
	})
	mux.HandleFunc("POST /v1/auth/oauth/{provider}/finish", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			State    string `json:"state"`
			Code     string `json:"code"`
			DeviceID string `json:"device_id"`
		}
		if !decode(w, r, &req) {
			return
		}
		phone, err := s.oauth.Finish(r.Context(), r.PathValue("provider"), req.State, req.Code, req.DeviceID)
		if err != nil {
			s.oauthError(w, err)
			return
		}
		sess, err := s.auth.SessionForPhone(r.Context(), phone)
		if err != nil {
			s.authError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"token": sess.Token, "registered": sess.Registered})
	})
}

func (s *Server) oauthError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, oauth.ErrUnknownProvider):
		writeError(w, http.StatusNotFound, err.Error())
	case errors.Is(err, oauth.ErrNoPhone):
		writeError(w, http.StatusUnprocessableEntity, err.Error())
	case errors.Is(err, oauth.ErrExpired), errors.Is(err, oauth.ErrDenied):
		writeError(w, http.StatusBadRequest, err.Error())
	default:
		s.log.Error("oauth", "err", err)
		writeError(w, http.StatusBadGateway, "сервис входа не отвечает — попробуйте позже или войдите по звонку")
	}
}
