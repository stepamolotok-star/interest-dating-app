package cities

import "testing"

func TestCatalog(t *testing.T) {
	c, err := Default()
	if err != nil {
		t.Fatal(err)
	}
	chita, ok := c.FindByName("чита")
	if !ok || chita.Region != "Забайкальский край" || chita.TZ != "Asia/Chita" {
		t.Fatalf("Чита: %+v", chita)
	}
	if got, _ := c.Get(chita.ID); got.Label() != "Чита, Забайкальский край" {
		t.Fatalf("Label: %q", got.Label())
	}
	// Одноимённые города различаются регионом и по названию не угадываются.
	if _, ok := c.FindByName("Советск"); ok {
		t.Fatal("Советсков три — по одному названию выбирать нельзя")
	}
	if x, ok := c.FindByName("Советск, Тульская область"); !ok || x.Region != "Тульская область" {
		t.Fatalf("Советск с регионом: %+v", x)
	}
	res := c.Search("мо", 3)
	if len(res) != 3 || res[0].Name != "Москва" {
		t.Fatalf("поиск «мо»: %+v", res)
	}
	if res := c.Search("петербург", 5); len(res) == 0 || res[0].Name != "Санкт-Петербург" {
		t.Fatalf("поиск по части названия: %+v", res)
	}
	if res := c.Search("орёл", 5); len(res) == 0 || res[0].Name != "Орёл" {
		t.Fatalf("ё и е: %+v", res)
	}
}
