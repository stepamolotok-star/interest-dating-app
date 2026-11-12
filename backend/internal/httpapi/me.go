package httpapi

import (
	"errors"
	"net/http"
	"strconv"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/chat"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/feed"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/matching"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/profile"
)

func (s *Server) registerProfile(mux *http.ServeMux) {
	h := func(pattern string, fn http.HandlerFunc) { mux.Handle(pattern, s.withUser(fn)) }
	h("GET /v1/me/profile", s.getProfile)
	h("PUT /v1/me/profile", s.putProfile)
	h("GET /v1/me/visibility", s.getVisibility)
	h("PUT /v1/me/visibility", s.putVisibility)
	h("GET /v1/me/interests", s.getInterests)
	h("PUT /v1/me/interests", s.putInterests)
	h("GET /v1/me/goals", s.getGoals)
	h("PUT /v1/me/goals", s.putGoals)
	h("GET /v1/me/prefs/{goal}", s.getPrefs)
	h("PUT /v1/me/prefs/{goal}", s.putPrefs)
	if s.feed != nil {
		h("GET /v1/feed", s.getFeed)
		h("POST /v1/feed/{user_id}/interest", s.postInterest)
		h("POST /v1/feed/{user_id}/skip", s.postSkip)
	}
	if s.chat != nil {
		h("GET /v1/matches", s.getMatches)
		h("GET /v1/matches/{id}/messages", s.getMessages)
		h("POST /v1/matches/{id}/messages", s.postMessage)
		h("POST /v1/matches/{id}/end", s.postEnd)
		h("POST /v1/users/{id}/block", s.postBlock)
		h("POST /v1/users/{id}/report", s.postReport)
	}
}

// withUser — только для пользователей, завершивших регистрацию.
func (s *Server) withUser(next http.HandlerFunc) http.Handler {
	return s.withSession(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if identity(r.Context()).UserID == "" {
			writeError(w, http.StatusForbidden, "сначала завершите регистрацию")
			return
		}
		next(w, r)
	}))
}

func uid(r *http.Request) string { return identity(r.Context()).UserID }

func (s *Server) getProfile(w http.ResponseWriter, r *http.Request) {
	f, err := s.profile.Get(r.Context(), uid(r))
	s.respond(w, f, err)
}

func (s *Server) putProfile(w http.ResponseWriter, r *http.Request) {
	var req struct {
		profile.Fields
		Consents struct {
			SpecialCategory bool `json:"special_category"`
		} `json:"consents"`
	}
	if !decode(w, r, &req) {
		return
	}
	err := s.profile.Update(r.Context(), uid(r), req.Fields, req.Consents.SpecialCategory, DocVersion)
	s.respond(w, nil, err)
}

func (s *Server) getVisibility(w http.ResponseWriter, r *http.Request) {
	v, err := s.profile.Visibility(r.Context(), uid(r))
	s.respond(w, v, err)
}

func (s *Server) putVisibility(w http.ResponseWriter, r *http.Request) {
	var req map[string]string
	if !decode(w, r, &req) {
		return
	}
	s.respond(w, nil, s.profile.SetVisibility(r.Context(), uid(r), req))
}

func (s *Server) getInterests(w http.ResponseWriter, r *http.Request) {
	items, err := s.profile.Interests(r.Context(), uid(r))
	s.respond(w, map[string]any{"items": items}, err)
}

func (s *Server) putInterests(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Items []profile.Interest `json:"items"`
	}
	if !decode(w, r, &req) {
		return
	}
	s.respond(w, nil, s.profile.SetInterests(r.Context(), uid(r), req.Items))
}

func (s *Server) getGoals(w http.ResponseWriter, r *http.Request) {
	g, err := s.profile.Goals(r.Context(), uid(r))
	s.respond(w, map[string]any{"goals": g}, err)
}

func (s *Server) putGoals(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Goals []profile.GoalSetting `json:"goals"`
	}
	if !decode(w, r, &req) {
		return
	}
	s.respond(w, nil, s.profile.SetGoals(r.Context(), uid(r), req.Goals))
}

func (s *Server) getPrefs(w http.ResponseWriter, r *http.Request) {
	p, err := s.profile.Prefs(r.Context(), uid(r), matching.Goal(r.PathValue("goal")))
	s.respond(w, p, err)
}

func (s *Server) putPrefs(w http.ResponseWriter, r *http.Request) {
	var p matching.Prefs
	if !decode(w, r, &p) {
		return
	}
	s.respond(w, nil, s.profile.SetPrefs(r.Context(), uid(r), matching.Goal(r.PathValue("goal")), p))
}

func (s *Server) getFeed(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	cards, err := s.feed.Feed(r.Context(), uid(r), matching.Goal(r.URL.Query().Get("goal")), limit)
	s.respond(w, map[string]any{"items": cards}, err)
}

func (s *Server) postInterest(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Goal       matching.Goal `json:"goal"`
		InterestID string        `json:"interest_id"`
	}
	if !decode(w, r, &req) {
		return
	}
	res, err := s.feed.Interest(r.Context(), uid(r), r.PathValue("user_id"), req.Goal, req.InterestID)
	s.respond(w, res, err)
}

func (s *Server) postSkip(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Goal matching.Goal `json:"goal"`
	}
	if !decode(w, r, &req) {
		return
	}
	s.respond(w, nil, s.feed.Skip(r.Context(), uid(r), r.PathValue("user_id"), req.Goal))
}

// respond пишет результат или переводит ошибку в понятный ответ.
func (s *Server) respond(w http.ResponseWriter, v any, err error) {
	var invalid *profile.ValidationError
	switch {
	case err == nil && v == nil:
		w.WriteHeader(http.StatusNoContent)
	case err == nil:
		writeJSON(w, http.StatusOK, v)
	case errors.As(err, &invalid):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": invalid.Message, "field": invalid.Field})
	case errors.Is(err, profile.ErrNeedVerification), errors.Is(err, profile.ErrNeedSpecialConsent),
		errors.Is(err, feed.ErrGoalNotActive):
		writeError(w, http.StatusForbidden, err.Error())
	case errors.Is(err, chat.ErrContactsInHello):
		writeError(w, http.StatusUnprocessableEntity, err.Error())
	case errors.Is(err, chat.ErrEmpty), errors.Is(err, chat.ErrTooLong), errors.Is(err, chat.ErrBadReason):
		writeError(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, profile.ErrNotFound), errors.Is(err, feed.ErrNotAvailable), errors.Is(err, chat.ErrNotFound):
		writeError(w, http.StatusNotFound, err.Error())
	default:
		s.log.Error("ошибка запроса", "err", err)
		writeError(w, http.StatusInternalServerError, "что-то пошло не так, попробуйте ещё раз")
	}
}

func (s *Server) getMatches(w http.ResponseWriter, r *http.Request) {
	items, err := s.chat.Matches(r.Context(), uid(r))
	s.respond(w, map[string]any{"items": items}, err)
}

func (s *Server) getMessages(w http.ResponseWriter, r *http.Request) {
	before, _ := strconv.ParseInt(r.URL.Query().Get("before"), 10, 64)
	items, err := s.chat.Messages(r.Context(), uid(r), r.PathValue("id"), before)
	s.respond(w, map[string]any{"items": items}, err)
}

func (s *Server) postMessage(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Body string `json:"body"`
	}
	if !decode(w, r, &req) {
		return
	}
	m, err := s.chat.Send(r.Context(), uid(r), r.PathValue("id"), req.Body)
	s.respond(w, m, err)
}

func (s *Server) postEnd(w http.ResponseWriter, r *http.Request) {
	s.respond(w, nil, s.chat.End(r.Context(), uid(r), r.PathValue("id")))
}

func (s *Server) postBlock(w http.ResponseWriter, r *http.Request) {
	s.respond(w, nil, s.chat.Block(r.Context(), uid(r), r.PathValue("id")))
}

func (s *Server) postReport(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Reason  string `json:"reason"`
		Comment string `json:"comment"`
	}
	if !decode(w, r, &req) {
		return
	}
	urgent, err := s.chat.Report(r.Context(), uid(r), r.PathValue("id"), req.Reason, req.Comment)
	s.respond(w, map[string]bool{"accepted": true, "urgent": urgent}, err)
}
