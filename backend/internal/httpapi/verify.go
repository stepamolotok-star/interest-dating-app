package httpapi

import (
	"errors"
	"io"
	"net/http"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/photos"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/verify"
)

func (s *Server) registerVerify(mux *http.ServeMux) {
	h := func(pattern string, fn http.HandlerFunc) { mux.Handle(pattern, s.withUser(fn)) }
	h("GET /v1/me/verification", func(w http.ResponseWriter, r *http.Request) {
		st, err := s.verify.Get(r.Context(), uid(r))
		s.respond(w, st, err)
	})
	h("POST /v1/me/verification", func(w http.ResponseWriter, r *http.Request) {
		st, err := s.verify.Start(r.Context(), uid(r))
		s.respond(w, st, err)
	})
	h("POST /v1/me/verification/{id}/selfie", func(w http.ResponseWriter, r *http.Request) {
		data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, photos.MaxUploadBytes+1))
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) || len(data) > photos.MaxUploadBytes {
			s.respond(w, nil, photos.ErrTooBig)
			return
		}
		if err != nil {
			writeError(w, http.StatusBadRequest, "не удалось получить файл")
			return
		}
		st, err := s.verify.Submit(r.Context(), uid(r), r.PathValue("id"), data)
		s.respond(w, st, err)
	})
}

// Очередь селфи для модератора (под тем же ключом, что жалобы).
func (s *Server) registerVerifyAdmin(h func(string, http.HandlerFunc)) {
	h("GET /admin/api/verifications", func(w http.ResponseWriter, r *http.Request) {
		items, err := s.verify.Queue(r.Context())
		s.adminRespond(w, map[string]any{"items": items, "reasons": verify.Reasons}, err)
	})
	h("GET /admin/api/verifications/{id}/selfie", func(w http.ResponseWriter, r *http.Request) {
		data, err := s.verify.Selfie(r.Context(), r.PathValue("id"))
		if errors.Is(err, verify.ErrNotFound) {
			writeError(w, http.StatusNotFound, err.Error())
			return
		}
		if err != nil {
			s.adminRespond(w, nil, err)
			return
		}
		writeImage(w, data)
	})
	h("POST /admin/api/verifications/{id}/decide", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Approve bool   `json:"approve"`
			Note    string `json:"note"`
		}
		if !decode(w, r, &req) {
			return
		}
		userID, err := s.verify.Decide(r.Context(), r.PathValue("id"), moderator(r), req.Approve, req.Note)
		if errors.Is(err, verify.ErrNotFound) {
			writeError(w, http.StatusNotFound, "селфи уже проверено или не найдено")
			return
		}
		if err == nil && s.notify != nil {
			s.notify.Verified(r.Context(), userID, req.Approve)
		}
		s.adminRespond(w, nil, err)
	})
}
