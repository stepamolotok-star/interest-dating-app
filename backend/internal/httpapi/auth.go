package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/auth"
)

// DocVersion — текущая версия соглашения и согласия на обработку ПДн.
const DocVersion = "2026-11"

type ctxKey struct{}

func (s *Server) registerAuth(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/auth/start", s.authStart)
	mux.HandleFunc("POST /v1/auth/verify", s.authVerify)
	mux.Handle("POST /v1/auth/register", s.withSession(http.HandlerFunc(s.authRegister)))
	mux.Handle("POST /v1/auth/logout", s.withSession(http.HandlerFunc(s.authLogout)))
	mux.Handle("GET /v1/me", s.withSession(http.HandlerFunc(s.me)))
}

func (s *Server) authStart(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Phone  string      `json:"phone"`
		Method auth.Method `json:"method"`
	}
	if !decode(w, r, &req) {
		return
	}
	ch, err := s.auth.Start(r.Context(), req.Phone, req.Method)
	if err != nil {
		s.authError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"method":       ch.Method,
		"code_length":  ch.CodeLength,
		"expires_in":   int(ch.ExpiresIn.Seconds()),
		"resend_after": int(ch.ResendAfter.Seconds()),
	})
}

func (s *Server) authVerify(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Phone string `json:"phone"`
		Code  string `json:"code"`
	}
	if !decode(w, r, &req) {
		return
	}
	sess, err := s.auth.Verify(r.Context(), req.Phone, req.Code)
	if err != nil {
		s.authError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"token": sess.Token, "registered": sess.Registered})
}

func (s *Server) authRegister(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name      string `json:"name"`
		BirthDate string `json:"birth_date"` // ГГГГ-ММ-ДД
		Gender    string `json:"gender"`
		City      string `json:"city"`
		Consents  struct {
			Terms        bool `json:"terms"`
			PersonalData bool `json:"personal_data"`
		} `json:"consents"`
	}
	if !decode(w, r, &req) {
		return
	}
	birth, err := time.Parse("2006-01-02", req.BirthDate)
	if err != nil {
		writeError(w, http.StatusBadRequest, "дата рождения в формате ГГГГ-ММ-ДД")
		return
	}
	userID, err := s.auth.Register(r.Context(), bearer(r), auth.Registration{
		Name: req.Name, BirthDate: birth, Gender: req.Gender, City: req.City,
		Terms: req.Consents.Terms, PersonalData: req.Consents.PersonalData, DocVersion: DocVersion,
	})
	if err != nil {
		s.authError(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"user_id": userID})
}

func (s *Server) authLogout(w http.ResponseWriter, r *http.Request) {
	if err := s.auth.Logout(r.Context(), bearer(r)); err != nil {
		s.authError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) me(w http.ResponseWriter, r *http.Request) {
	id := identity(r.Context())
	if id.UserID == "" {
		writeError(w, http.StatusForbidden, "сначала завершите регистрацию")
		return
	}
	m, err := s.auth.Me(r.Context(), id.UserID)
	if err != nil {
		s.authError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, m)
}

// withSession пропускает запрос только с действующим токеном сессии.
func (s *Server) withSession(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id, err := s.auth.Authenticate(r.Context(), bearer(r))
		if err != nil {
			s.authError(w, err)
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), ctxKey{}, id)))
	})
}

func identity(ctx context.Context) auth.Identity {
	id, _ := ctx.Value(ctxKey{}).(auth.Identity)
	return id
}

func bearer(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if t, ok := strings.CutPrefix(h, "Bearer "); ok {
		return strings.TrimSpace(t)
	}
	return ""
}

// authError переводит ошибки входа в HTTP-ответы с понятным текстом.
func (s *Server) authError(w http.ResponseWriter, err error) {
	var retry *auth.RetryError
	var invalid *auth.ValidationError
	switch {
	case errors.As(err, &retry):
		w.Header().Set("Retry-After", strconv.Itoa(int(math.Ceil(retry.After.Seconds()))))
		writeError(w, http.StatusTooManyRequests, err.Error())
	case errors.Is(err, auth.ErrTooManyAttempts):
		writeError(w, http.StatusTooManyRequests, err.Error())
	case errors.As(err, &invalid):
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": invalid.Message, "field": invalid.Field})
	case errors.Is(err, auth.ErrNotRussianMobile), errors.Is(err, auth.ErrWrongCode),
		errors.Is(err, auth.ErrNoActiveCode), errors.Is(err, auth.ErrConsentsRequired):
		writeError(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, auth.ErrUnderage):
		writeError(w, http.StatusForbidden, err.Error())
	case errors.Is(err, auth.ErrUnauthorized):
		writeError(w, http.StatusUnauthorized, err.Error())
	case errors.Is(err, auth.ErrAlreadyRegistered):
		writeError(w, http.StatusConflict, err.Error())
	default:
		s.log.Error("ошибка входа", "err", err)
		writeError(w, http.StatusInternalServerError, "что-то пошло не так, попробуйте ещё раз")
	}
}

func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, 16<<10)
	if err := json.NewDecoder(r.Body).Decode(v); err != nil {
		writeError(w, http.StatusBadRequest, "некорректный JSON")
		return false
	}
	return true
}

// decodeLarge — как decode, но лимит размера тела задаёт вызывающий.
func decodeLarge(w http.ResponseWriter, r *http.Request, v any) bool {
	if err := json.NewDecoder(r.Body).Decode(v); err != nil {
		writeError(w, http.StatusBadRequest, "некорректный JSON или слишком большой запрос")
		return false
	}
	return true
}
