package httpapi

import (
	"errors"
	"io"
	"net/http"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/feed"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/photos"
)

func (s *Server) registerPhotos(mux *http.ServeMux) {
	h := func(pattern string, fn http.HandlerFunc) { mux.Handle(pattern, s.withUser(fn)) }
	h("GET /v1/me/photos", func(w http.ResponseWriter, r *http.Request) {
		items, err := s.photos.List(r.Context(), uid(r))
		s.respond(w, map[string]any{"items": items}, err)
	})
	h("POST /v1/me/photos", func(w http.ResponseWriter, r *http.Request) {
		// Тело — сам файл. Один лишний байт сверх предела покажет, что файл слишком большой.
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
		p, err := s.photos.Upload(r.Context(), uid(r), data)
		s.respond(w, p, err)
	})
	h("DELETE /v1/me/photos/{id}", func(w http.ResponseWriter, r *http.Request) {
		s.respond(w, nil, s.photos.Delete(r.Context(), uid(r), r.PathValue("id")))
	})
	h("PUT /v1/me/photos/order", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			IDs []string `json:"ids"`
		}
		if !decode(w, r, &req) {
			return
		}
		s.respond(w, nil, s.photos.Reorder(r.Context(), uid(r), req.IDs))
	})
	h("GET /v1/photos/{id}", func(w http.ResponseWriter, r *http.Request) {
		data, err := s.photos.Open(r.Context(), uid(r), r.PathValue("id"), feed.VisibleUserSQL)
		if err != nil {
			s.respond(w, nil, err)
			return
		}
		writeImage(w, data)
	})
}

// writeImage отдаёт JPEG. Фото по id не меняется, поэтому телефон может держать его в кэше.
func writeImage(w http.ResponseWriter, data []byte) {
	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Cache-Control", "private, max-age=604800, immutable")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}
