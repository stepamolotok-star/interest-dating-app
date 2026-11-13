// Package catalog — дерево интересов: категория → подкатегория → увлечение.
//
// Дерево используется не только для навигации: по нему считается частичное
// совпадение интересов (эндуро и мототуризм — одна подкатегория).
package catalog

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

//go:embed catalog.json
var defaultCatalog []byte

// Node — узел каталога.
type Node struct {
	ID       string   `json:"id"`
	Parent   string   `json:"parent,omitempty"`
	Name     string   `json:"name"`
	Synonyms []string `json:"synonyms,omitempty"`
	Depth    int      `json:"depth"` // 0 — категория, 1 — подкатегория, 2 — увлечение

	// Kind — вид увлечения. KindFan — то, чем наслаждаются, а не занимаются
	// (слушаю рок, смотрю кино, кошки): у таких нет степени увлечённости.
	// Задаётся на подкатегории и наследуется увлечениями.
	Kind string `json:"kind,omitempty"`
}

// KindFan — увлечение «слушаю/смотрю/люблю», без степени увлечённости.
const KindFan = "fan"

// IsFan — увлечение без степени увлечённости.
func (n Node) IsFan() bool { return n.Kind == KindFan }

// Catalog — неизменяемый после загрузки каталог; безопасен для параллельного чтения.
type Catalog struct {
	nodes    map[string]*Node
	children map[string][]string
	roots    []string
}

// Default загружает встроенный стартовый каталог.
func Default() (*Catalog, error) { return Parse(defaultCatalog) }

// Parse разбирает каталог из JSON вида {"nodes":[{id,parent,name,synonyms}]}.
func Parse(data []byte) (*Catalog, error) {
	var raw struct {
		Nodes []Node `json:"nodes"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("catalog: разбор JSON: %w", err)
	}
	c := &Catalog{nodes: make(map[string]*Node, len(raw.Nodes)), children: map[string][]string{}}
	for i := range raw.Nodes {
		n := raw.Nodes[i]
		if n.ID == "" || n.Name == "" {
			return nil, fmt.Errorf("catalog: узел без id или названия: %+v", n)
		}
		if _, dup := c.nodes[n.ID]; dup {
			return nil, fmt.Errorf("catalog: повтор id %q", n.ID)
		}
		c.nodes[n.ID] = &n
	}
	for _, n := range raw.Nodes {
		if n.Parent == "" {
			c.roots = append(c.roots, n.ID)
			continue
		}
		if _, ok := c.nodes[n.Parent]; !ok {
			return nil, fmt.Errorf("catalog: у %q нет родителя %q", n.ID, n.Parent)
		}
		c.children[n.Parent] = append(c.children[n.Parent], n.ID)
	}
	for _, n := range c.nodes {
		d := 0
		for p := n.Parent; p != ""; p = c.nodes[p].Parent {
			d++
			if d > 2 {
				return nil, fmt.Errorf("catalog: %q глубже трёх уровней", n.ID)
			}
		}
		n.Depth = d
	}
	for _, n := range c.nodes {
		for p := n.Parent; n.Kind == "" && p != ""; p = c.nodes[p].Parent {
			n.Kind = c.nodes[p].Kind
		}
	}
	return c, nil
}

// Get возвращает узел по id.
func (c *Catalog) Get(id string) (Node, bool) {
	n, ok := c.nodes[id]
	if !ok {
		return Node{}, false
	}
	return *n, true
}

// Name возвращает название узла или сам id, если узла нет.
func (c *Catalog) Name(id string) string {
	if n, ok := c.nodes[id]; ok {
		return n.Name
	}
	return id
}

// Categories — корневые категории в порядке каталога.
func (c *Catalog) Categories() []Node { return c.list(c.roots) }

// Children — прямые потомки узла.
func (c *Catalog) Children(id string) []Node { return c.list(c.children[id]) }

// Len — число узлов.
func (c *Catalog) Len() int { return len(c.nodes) }

func (c *Catalog) list(ids []string) []Node {
	out := make([]Node, 0, len(ids))
	for _, id := range ids {
		out = append(out, *c.nodes[id])
	}
	return out
}

// Path — названия от категории до узла: ["Техника и транспорт", "Мотоциклы", "Эндуро"].
func (c *Catalog) Path(id string) []string {
	var path []string
	for n, ok := c.nodes[id]; ok; n, ok = c.nodes[n.Parent] {
		path = append([]string{n.Name}, path...)
		if n.Parent == "" {
			break
		}
	}
	return path
}

// ancestorAt возвращает предка узла на заданной глубине (или сам узел).
func (c *Catalog) ancestorAt(id string, depth int) string {
	n, ok := c.nodes[id]
	for ok && n.Depth > depth {
		n, ok = c.nodes[n.Parent]
	}
	if !ok || n.Depth != depth {
		return ""
	}
	return n.ID
}

// Similarity — насколько близки два интереса (ТЗ, раздел 5):
// одно и то же — 1, одна подкатегория — 0.5, одна категория — 0.2, иначе 0.
func (c *Catalog) Similarity(a, b string) float64 {
	if a == b {
		if _, ok := c.nodes[a]; ok {
			return 1
		}
		return 0
	}
	if sa := c.ancestorAt(a, 1); sa != "" && sa == c.ancestorAt(b, 1) {
		return 0.5
	}
	if ca := c.ancestorAt(a, 0); ca != "" && ca == c.ancestorAt(b, 0) {
		return 0.2
	}
	return 0
}

// Normalize приводит строку к виду для поиска: нижний регистр, «ё» → «е».
func Normalize(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	return strings.ReplaceAll(s, "ё", "е")
}

// Search ищет по названиям и синонимам. Порядок: точное совпадение,
// начало слова, вхождение; внутри — сначала конкретные увлечения.
func (c *Catalog) Search(query string, limit int) []Node {
	q := Normalize(query)
	if q == "" || limit <= 0 {
		return nil
	}
	type hit struct {
		id   string
		rank int
	}
	var hits []hit
	for id, n := range c.nodes {
		best := -1
		for _, term := range append([]string{n.Name}, n.Synonyms...) {
			t := Normalize(term)
			r := -1
			switch {
			case t == q:
				r = 0
			case strings.HasPrefix(t, q) || strings.Contains(t, " "+q):
				r = 1
			case strings.Contains(t, q):
				r = 2
			}
			if r >= 0 && (best < 0 || r < best) {
				best = r
			}
		}
		if best >= 0 {
			hits = append(hits, hit{id, best*10 + (2 - n.Depth)})
		}
	}
	sort.Slice(hits, func(i, j int) bool {
		if hits[i].rank != hits[j].rank {
			return hits[i].rank < hits[j].rank
		}
		return hits[i].id < hits[j].id
	})
	if len(hits) > limit {
		hits = hits[:limit]
	}
	out := make([]Node, len(hits))
	for i, h := range hits {
		out[i] = *c.nodes[h.id]
	}
	return out
}
