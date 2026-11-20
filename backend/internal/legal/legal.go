// Package legal — пользовательские документы: политика, согласия, соглашение,
// правила сообщества и правила рекомендательных технологий.
//
// Тексты лежат в texts/*.md (та же копия — в mobile/assets/legal). Данные оператора
// подставляются из настроек, чтобы при смене названия или оператора не править тексты.
// Сервер отдаёт документы страницами /legal/{имя}: ссылка нужна RuStore и для писем.
package legal

import (
	"embed"
	"fmt"
	"html"
	"strings"
)

// Version — редакция документов: её номер записывается вместе с согласием.
// Меняется вместе с текстами (и Updated).
const Version = "2026-11-21"

// Updated — дата редакции словами, для текста документов.
const Updated = "21 ноября 2026 г."

//go:embed texts/*.md
var texts embed.FS

// Doc — документ.
type Doc struct {
	Name  string // имя файла без .md и адрес страницы
	Title string
}

// Docs — все документы в порядке показа.
var Docs = []Doc{
	{"terms", "Пользовательское соглашение"},
	{"privacy", "Политика обработки персональных данных"},
	{"personal-data", "Согласие на обработку персональных данных"},
	{"special-category", "Согласие на обработку сведений о религиозных убеждениях"},
	{"rules", "Правила сообщества"},
	{"recommendations", "Правила применения рекомендательных технологий"},
}

// Vars — данные для подстановки. Пустые поля остаются заметными метками в квадратных скобках.
type Vars struct {
	App        string // название приложения
	Operator   string // ФИО (или «ИП …»)
	OperatorID string // ИНН, ОГРНИП
	Email      string // почта для обращений
}

func (v Vars) replacer() *strings.Replacer {
	or := func(s, def string) string {
		if strings.TrimSpace(s) == "" {
			return def
		}
		return s
	}
	return strings.NewReplacer(
		"{{APP}}", or(v.App, "Свои"),
		"{{OPERATOR}}", or(v.Operator, "[ФИО оператора]"),
		"{{OPERATOR_ID}}", or(v.OperatorID, "[ИНН оператора]"),
		"{{EMAIL}}", or(v.Email, "[адрес электронной почты]"),
		"{{UPDATED}}", Updated,
	)
}

// Find — документ по имени.
func Find(name string) (Doc, bool) {
	for _, d := range Docs {
		if d.Name == name {
			return d, true
		}
	}
	return Doc{}, false
}

// Text — текст документа (Markdown) с подставленными данными.
func Text(name string, v Vars) (string, error) {
	if _, ok := Find(name); !ok {
		return "", fmt.Errorf("legal: нет документа %q", name)
	}
	b, err := texts.ReadFile("texts/" + name + ".md")
	if err != nil {
		return "", err
	}
	return v.replacer().Replace(string(b)), nil
}

// HTML переводит текст документа в HTML. Разметка — простая: заголовки «#», «##»,
// абзацы, списки «-» и «1.», вложенный список с отступом, **жирный**.
func HTML(md string) string {
	var b strings.Builder
	var para []string
	list := "" // "ul" / "ol" / ""
	sub := false
	itemOpen := false
	flushPara := func() {
		if len(para) > 0 {
			b.WriteString("<p>" + inline(strings.Join(para, " ")) + "</p>\n")
			para = nil
		}
	}
	closeSub := func() {
		if sub {
			b.WriteString("</ul>")
			sub = false
		}
	}
	closeList := func() {
		closeSub()
		if itemOpen {
			b.WriteString("</li>\n")
			itemOpen = false
		}
		if list != "" {
			b.WriteString("</" + list + ">\n")
			list = ""
		}
	}
	for _, raw := range strings.Split(md, "\n") {
		line := strings.TrimRight(raw, " \t\r")
		trimmed := strings.TrimLeft(line, " ")
		indented := len(line)-len(trimmed) >= 2
		switch {
		case trimmed == "":
			flushPara()
			closeList()
		case strings.HasPrefix(line, "# "):
			flushPara()
			closeList()
			b.WriteString("<h1>" + inline(line[2:]) + "</h1>\n")
		case strings.HasPrefix(line, "## "):
			flushPara()
			closeList()
			b.WriteString("<h2>" + inline(line[3:]) + "</h2>\n")
		case indented && strings.HasPrefix(trimmed, "- ") && itemOpen:
			if !sub {
				b.WriteString("<ul>")
				sub = true
			}
			b.WriteString("<li>" + inline(trimmed[2:]) + "</li>")
		case strings.HasPrefix(line, "- "), isOrdered(line):
			flushPara()
			kind, text := "ul", line[2:]
			if isOrdered(line) {
				kind, text = "ol", line[strings.Index(line, ". ")+2:]
			}
			if list != kind {
				closeList()
				b.WriteString("<" + kind + ">\n")
				list = kind
			}
			closeSub()
			if itemOpen {
				b.WriteString("</li>\n")
			}
			b.WriteString("<li>" + inline(text))
			itemOpen = true
		default:
			if list != "" {
				closeList()
			}
			para = append(para, strings.TrimSpace(line))
		}
	}
	flushPara()
	closeList()
	return b.String()
}

func isOrdered(line string) bool {
	i := 0
	for i < len(line) && line[i] >= '0' && line[i] <= '9' {
		i++
	}
	return i > 0 && strings.HasPrefix(line[i:], ". ")
}

// inline экранирует HTML и превращает **жирный** в <b>.
func inline(s string) string {
	parts := strings.Split(html.EscapeString(s), "**")
	var b strings.Builder
	for i, p := range parts {
		if i%2 == 1 && i < len(parts)-1 {
			b.WriteString("<b>" + p + "</b>")
		} else {
			if i%2 == 1 {
				b.WriteString("**")
			}
			b.WriteString(p)
		}
	}
	return b.String()
}
