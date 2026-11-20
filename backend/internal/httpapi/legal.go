package httpapi

import (
	"errors"
	"html"
	"net/http"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/account"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/legal"
)

// Документы — публичные страницы: ссылки нужны RuStore, в письмах и до регистрации.
func (s *Server) registerLegal(mux *http.ServeMux) {
	mux.HandleFunc("GET /legal/{$}", func(w http.ResponseWriter, r *http.Request) {
		body := "<h1>Документы</h1>\n<ul>\n"
		for _, d := range legal.Docs {
			body += `<li><a href="/legal/` + d.Name + `">` + html.EscapeString(d.Title) + "</a></li>\n"
		}
		writeLegalPage(w, "Документы", body+"</ul>\n")
	})
	mux.HandleFunc("GET /legal/{name}", func(w http.ResponseWriter, r *http.Request) {
		d, ok := legal.Find(r.PathValue("name"))
		if !ok {
			http.NotFound(w, r)
			return
		}
		md, err := legal.Text(d.Name, s.legal)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "внутренняя ошибка")
			return
		}
		writeLegalPage(w, d.Title, legal.HTML(md)+`<p class="back"><a href="/legal/">Все документы</a></p>`)
	})
}

func writeLegalPage(w http.ResponseWriter, title, body string) {
	h := w.Header()
	h.Set("Content-Type", "text/html; charset=utf-8")
	h.Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Cache-Control", "public, max-age=3600")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(`<!DOCTYPE html>
<html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>` + html.EscapeString(title) + `</title>
<style>
body { margin: 0; background: #f7f5f0; color: #1d2421; font: 17px/1.55 -apple-system, "Segoe UI", Roboto, sans-serif; }
main { max-width: 760px; margin: 0 auto; padding: 32px 20px 64px; }
h1 { font-size: 28px; line-height: 1.2; margin: 0 0 8px; }
h2 { font-size: 20px; margin: 32px 0 8px; }
a { color: #0e7a6a; }
li { margin: 4px 0; }
.back { margin-top: 40px; }
</style></head>
<body><main>
` + body + `</main></body></html>`))
}

func (s *Server) deleteAccount(w http.ResponseWriter, r *http.Request) {
	err := s.account.Delete(r.Context(), uid(r))
	if errors.Is(err, account.ErrNotFound) {
		writeError(w, http.StatusNotFound, "аккаунт уже удалён")
		return
	}
	s.respond(w, nil, err)
}
