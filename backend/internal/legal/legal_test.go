package legal

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTexts(t *testing.T) {
	v := Vars{App: "Свои", Operator: "Иванов Иван Иванович", OperatorID: "ИНН 000000000000", Email: "help@example.ru"}
	for _, d := range Docs {
		md, err := Text(d.Name, v)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(md, "{{") {
			t.Errorf("%s: осталась неподставленная метка", d.Name)
		}
		if !strings.HasPrefix(md, "# "+d.Title+"\n") {
			t.Errorf("%s: заголовок не совпадает с %q", d.Name, d.Title)
		}
		if !strings.Contains(md, Updated) {
			t.Errorf("%s: нет даты редакции", d.Name)
		}
	}
	// Без настроек метки заметны, но не ломают текст.
	md, _ := Text("privacy", Vars{})
	if !strings.Contains(md, "[ФИО оператора]") || !strings.Contains(md, "[адрес электронной почты]") {
		t.Fatal("метки по умолчанию")
	}
}

func TestHTML(t *testing.T) {
	got := HTML("# Заголовок\n\nАбзац **жирный** <script>\nпродолжение\n\n## Раздел\n\n- один\n- два\n\n1. **Шаг.** текст\n   - вложенный\n   - ещё\n2. второй\n")
	for _, want := range []string{
		"<h1>Заголовок</h1>",
		"<p>Абзац <b>жирный</b> &lt;script&gt; продолжение</p>",
		"<h2>Раздел</h2>",
		"<ul>\n<li>один</li>\n<li>два</li>\n</ul>",
		"<ol>\n<li><b>Шаг.</b> текст<ul><li>вложенный</li><li>ещё</li></ul></li>\n<li>второй</li>\n</ol>",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("нет %q в\n%s", want, got)
		}
	}
}

// Приложение показывает те же тексты: копия в mobile/assets/legal не должна расходиться.
func TestMobileCopy(t *testing.T) {
	dir := filepath.Join("..", "..", "..", "mobile", "assets", "legal")
	if _, err := os.Stat(dir); err != nil {
		t.Skip("нет папки приложения")
	}
	for _, d := range Docs {
		a, _ := texts.ReadFile("texts/" + d.Name + ".md")
		b, err := os.ReadFile(filepath.Join(dir, d.Name+".md"))
		if err != nil || string(a) != string(b) {
			t.Errorf("%s: копия в mobile/assets/legal отличается — скопируйте из backend/internal/legal/texts", d.Name)
		}
	}
}
