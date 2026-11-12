package httpapi

import (
	"errors"
	"net/http"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/feed"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/matching"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/nearby"
)

func (s *Server) registerNearby(mux *http.ServeMux) {
	h := func(pattern string, fn http.HandlerFunc) { mux.Handle(pattern, s.withUser(fn)) }
	h("GET /v1/nearby/visibility", func(w http.ResponseWriter, r *http.Request) {
		v, err := s.nearby.GetVisibility(r.Context(), uid(r))
		s.nearbyRespond(w, v, err)
	})
	h("PUT /v1/nearby/visibility", func(w http.ResponseWriter, r *http.Request) {
		var in nearby.SetVisibilityInput
		if !decode(w, r, &in) {
			return
		}
		v, err := s.nearby.SetVisibility(r.Context(), uid(r), in)
		s.nearbyRespond(w, v, err)
	})
	h("POST /v1/nearby/disappear", func(w http.ResponseWriter, r *http.Request) {
		s.nearbyRespond(w, nil, s.nearby.Disappear(r.Context(), uid(r)))
	})
	h("GET /v1/nearby/zones", func(w http.ResponseWriter, r *http.Request) {
		z, err := s.nearby.Zones(r.Context(), uid(r))
		s.nearbyRespond(w, map[string]any{"items": z}, err)
	})
	h("POST /v1/nearby/zones", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			Name    string  `json:"name"`
			Lat     float64 `json:"lat"`
			Lon     float64 `json:"lon"`
			RadiusM int     `json:"radius_m"`
		}
		if !decode(w, r, &in) {
			return
		}
		z, err := s.nearby.AddZone(r.Context(), uid(r), in.Name, in.Lat, in.Lon, in.RadiusM)
		s.nearbyRespond(w, z, err)
	})
	h("DELETE /v1/nearby/zones/{id}", func(w http.ResponseWriter, r *http.Request) {
		s.nearbyRespond(w, nil, s.nearby.DeleteZone(r.Context(), uid(r), r.PathValue("id")))
	})
	h("POST /v1/nearby/location", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			Lat    float64 `json:"lat"`
			Lon    float64 `json:"lon"`
			Mocked bool    `json:"mocked"` // приложение сообщает, что включена подмена GPS
		}
		if !decode(w, r, &in) {
			return
		}
		st, err := s.nearby.UpdateLocation(r.Context(), uid(r), in.Lat, in.Lon, in.Mocked)
		s.nearbyRespond(w, st, err)
	})
	h("GET /v1/nearby/radar", func(w http.ResponseWriter, r *http.Request) {
		cards, err := s.nearby.Radar(r.Context(), uid(r), matching.Goal(r.URL.Query().Get("goal")))
		s.nearbyRespond(w, map[string]any{"items": cards}, err)
	})
	h("GET /v1/me/templates", func(w http.ResponseWriter, r *http.Request) {
		t, err := s.nearby.Templates(r.Context(), uid(r))
		s.nearbyRespond(w, map[string]any{"items": t}, err)
	})
	h("POST /v1/me/templates", func(w http.ResponseWriter, r *http.Request) {
		var t nearby.Template
		if !decode(w, r, &t) {
			return
		}
		out, err := s.nearby.CreateTemplate(r.Context(), uid(r), t)
		s.nearbyRespond(w, out, err)
	})
	h("DELETE /v1/me/templates/{id}", func(w http.ResponseWriter, r *http.Request) {
		s.nearbyRespond(w, nil, s.nearby.DeleteTemplate(r.Context(), uid(r), r.PathValue("id")))
	})
}

func (s *Server) nearbyRespond(w http.ResponseWriter, v any, err error) {
	var invalid *nearby.ValidationError
	switch {
	case err == nil:
		s.respond(w, v, nil)
	case errors.As(err, &invalid):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": invalid.Message, "field": invalid.Field})
	case errors.Is(err, nearby.ErrBadCoordinates):
		writeError(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, nearby.ErrSuspicious), errors.Is(err, nearby.ErrNotVisible), errors.Is(err, feed.ErrGoalNotActive):
		writeError(w, http.StatusForbidden, err.Error())
	case errors.Is(err, nearby.ErrNoLocation):
		writeError(w, http.StatusConflict, err.Error())
	case errors.Is(err, nearby.ErrTooFrequent):
		w.Header().Set("Retry-After", "60")
		writeError(w, http.StatusTooManyRequests, err.Error())
	default:
		s.respond(w, nil, err)
	}
}
