package httpapi

import (
	"errors"
	"net/http"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/contacts"
)

// «Скрыть меня от моих контактов».
func (s *Server) registerContacts(mux *http.ServeMux) {
	h := func(pattern string, fn http.HandlerFunc) { mux.Handle(pattern, s.withUser(fn)) }
	h("GET /v1/me/contacts", func(w http.ResponseWriter, r *http.Request) {
		st, err := s.contacts.Get(r.Context(), uid(r))
		s.contactsRespond(w, st, err)
	})
	h("PUT /v1/me/contacts", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			Hashes []string `json:"hashes"`
		}
		// 5000 хэшей по 64 символа — около 350 КБ.
		r.Body = http.MaxBytesReader(w, r.Body, 512<<10)
		if !decodeLarge(w, r, &in) {
			return
		}
		st, err := s.contacts.Upload(r.Context(), uid(r), in.Hashes, DocVersion)
		s.contactsRespond(w, st, err)
	})
	h("DELETE /v1/me/contacts", func(w http.ResponseWriter, r *http.Request) {
		s.contactsRespond(w, nil, s.contacts.Clear(r.Context(), uid(r)))
	})
}

func (s *Server) contactsRespond(w http.ResponseWriter, v any, err error) {
	var invalid *contacts.ValidationError
	if errors.As(err, &invalid) {
		writeError(w, http.StatusBadRequest, invalid.Message)
		return
	}
	s.respond(w, v, err)
}
