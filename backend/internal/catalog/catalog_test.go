package catalog

import "testing"

func mustDefault(t *testing.T) *Catalog {
	t.Helper()
	c, err := Default()
	if err != nil {
		t.Fatalf("Default: %v", err)
	}
	return c
}

func TestDefaultCatalogLoads(t *testing.T) {
	c := mustDefault(t)
	if got := len(c.Categories()); got < 20 {
		t.Fatalf("ожидали не меньше 20 категорий, получили %d", got)
	}
	n, ok := c.Get("transport.moto.enduro")
	if !ok || n.Depth != 2 || n.Name != "Эндуро" {
		t.Fatalf("эндуро: %+v %v", n, ok)
	}
	if got := c.Path("transport.moto.enduro"); len(got) != 3 || got[0] != "Техника и транспорт" {
		t.Fatalf("путь: %v", got)
	}
}

func TestSimilarity(t *testing.T) {
	c := mustDefault(t)
	cases := []struct {
		a, b string
		want float64
	}{
		{"transport.moto.enduro", "transport.moto.enduro", 1},
		{"transport.moto.enduro", "transport.moto.moto_touring", 0.5},
		{"transport.moto.enduro", "transport.auto.offroad", 0.2},
		{"transport.moto.enduro", "home.garden.bonsai", 0},
		{"нет.такого", "нет.такого", 0},
	}
	for _, tc := range cases {
		if got := c.Similarity(tc.a, tc.b); got != tc.want {
			t.Errorf("Similarity(%s, %s) = %v, ждали %v", tc.a, tc.b, got, tc.want)
		}
	}
}

func TestSearchFindsSynonymsAndYo(t *testing.T) {
	c := mustDefault(t)
	cases := map[string]string{
		"эндура":   "transport.moto.enduro",
		"серфинг":  "outdoor.water.surfing", // название «Сёрфинг»
		"НАСТОЛКИ": "games.table.boardgames",
		"бонсай":   "home.garden.bonsai",
	}
	for q, want := range cases {
		res := c.Search(q, 5)
		if len(res) == 0 || res[0].ID != want {
			t.Errorf("Search(%q): первый результат %v, ждали %s", q, ids(res), want)
		}
	}
	if res := c.Search("мото", 10); len(res) < 3 {
		t.Errorf("по «мото» ждали несколько результатов, получили %v", ids(res))
	}
	if res := c.Search("   ", 10); res != nil {
		t.Errorf("пустой запрос должен давать nil")
	}
}

func TestParseRejectsBrokenTree(t *testing.T) {
	bad := []string{
		`{"nodes":[{"id":"a","name":"A"},{"id":"a","name":"A2"}]}`,
		`{"nodes":[{"id":"a","parent":"нет","name":"A"}]}`,
		`{"nodes":[{"id":"a","name":"A"},{"id":"b","parent":"a","name":"B"},{"id":"c","parent":"b","name":"C"},{"id":"d","parent":"c","name":"D"}]}`,
	}
	for _, js := range bad {
		if _, err := Parse([]byte(js)); err == nil {
			t.Errorf("ожидали ошибку для %s", js)
		}
	}
}

func ids(nodes []Node) []string {
	out := make([]string, len(nodes))
	for i, n := range nodes {
		out[i] = n.ID
	}
	return out
}

func TestFanKindInherited(t *testing.T) {
	c, err := Default()
	if err != nil {
		t.Fatal(err)
	}
	rock, _ := c.Get("music.listen.rock")
	guitar, _ := c.Get("music.play.guitar")
	if !rock.IsFan() || guitar.IsFan() {
		t.Fatalf("rock fan=%v, guitar fan=%v", rock.IsFan(), guitar.IsFan())
	}
}
