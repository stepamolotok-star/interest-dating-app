// Package cities — справочник городов России для выбора города при регистрации.
//
// Данные: github.com/hflabs/city (CC BY-SA 4.0; координаты, коды ФИАС и часовые пояса —
// DaData.ru, население — Википедия). 1117 городов; сёл и посёлков в нём нет — для них
// человек выбирает ближайший город. Пересборка — gen.py.
package cities

import (
	_ "embed"
	"encoding/json"
	"sort"
	"strings"
)

//go:embed cities.json
var raw []byte

// City — город из справочника.
type City struct {
	ID     string  `json:"id"` // код ФИАС
	Name   string  `json:"name"`
	Region string  `json:"region"` // пусто у Москвы, Петербурга и Севастополя
	Lat    float64 `json:"lat"`
	Lon    float64 `json:"lon"`
	Pop    int     `json:"pop"`
	TZ     string  `json:"tz"` // часовой пояс IANA
}

// Label — «Чита, Забайкальский край».
func (c City) Label() string {
	if c.Region == "" {
		return c.Name
	}
	return c.Name + ", " + c.Region
}

// Catalog — все города, крупные первыми.
type Catalog struct {
	list []City
	byID map[string]City
}

// Default загружает встроенный справочник.
func Default() (*Catalog, error) {
	var data struct {
		Cities []City `json:"cities"`
	}
	if err := json.Unmarshal(raw, &data); err != nil {
		return nil, err
	}
	c := &Catalog{list: data.Cities, byID: make(map[string]City, len(data.Cities))}
	sort.SliceStable(c.list, func(i, j int) bool { return c.list[i].Pop > c.list[j].Pop })
	for _, x := range c.list {
		c.byID[x.ID] = x
	}
	return c, nil
}

// Get — город по коду ФИАС.
func (c *Catalog) Get(id string) (City, bool) {
	x, ok := c.byID[id]
	return x, ok
}

func norm(s string) string {
	return strings.ReplaceAll(strings.ToLower(strings.TrimSpace(s)), "ё", "е")
}

// Search — сначала точные совпадения, потом города, название которых начинается
// с запроса, потом содержащие его; внутри каждой группы — по населению.
func (c *Catalog) Search(q string, limit int) []City {
	q = norm(q)
	if q == "" || limit <= 0 {
		return nil
	}
	var exact, starts, contains []City
	for _, x := range c.list {
		n := norm(x.Name)
		switch {
		case n == q:
			exact = append(exact, x)
		case strings.HasPrefix(n, q):
			starts = append(starts, x)
		case strings.Contains(n, q):
			contains = append(contains, x)
		}
	}
	out := append(append(exact, starts...), contains...)
	if len(out) > limit {
		out = out[:limit]
	}
	return out
}

// FindByName — город по точному названию, если он такой один (для старых клиентов,
// которые присылают город текстом). Несколько одноимённых — ok=false.
func (c *Catalog) FindByName(name string) (City, bool) {
	n := norm(name)
	var found []City
	for _, x := range c.list {
		if norm(x.Name) == n || norm(x.Label()) == n {
			found = append(found, x)
		}
	}
	if len(found) != 1 {
		return City{}, false
	}
	return found[0], true
}
