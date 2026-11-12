// Package matching — кто кому подходит и насколько (ТЗ, раздел 5).
//
// Порядок такой: сначала Eligible отсекает пары, которые не проходят
// обязательные условия хотя бы с одной стороны, затем Score считает оценку
// совместимости 0–100 и человеческое объяснение для карточки.
package matching

import (
	"errors"
	"fmt"
	"math"
	"slices"
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// Goal — цель знакомства.
type Goal string

const (
	Romance    Goal = "romance"
	Casual     Goal = "casual" // «Без обязательств»
	Friendship Goal = "friendship"
	Hobby      Goal = "hobby"
	Talk       Goal = "talk"
	Travel     Goal = "travel"
	LikeMinded Goal = "likeminded"
)

// AllowsPhysical — можно ли в этой цели фильтровать по росту и весу.
func (g Goal) AllowsPhysical() bool { return g == Romance || g == Casual }

// Level — уровень вовлечённости в увлечение.
type Level string

const (
	Curious     Level = "curious"
	Doing       Level = "doing"
	Serious     Level = "serious"
	Pro         Level = "pro"
	WantToLearn Level = "want_to_learn"
)

// UserInterest — увлечение в профиле.
type UserInterest struct {
	ID             string
	Level          Level
	SeekingPartner bool // «ищу партнёра для этого» — вес ×2
}

// Range — диапазон «от–до» включительно; нулевой диапазон — «не задан».
type Range struct {
	Min int `json:"min,omitempty"`
	Max int `json:"max,omitempty"`
}

func (r Range) IsZero() bool        { return r.Min == 0 && r.Max == 0 }
func (r Range) Contains(v int) bool { return v >= r.Min && (r.Max == 0 || v <= r.Max) }

// Prefs — «портрет» искомого человека для одной цели. Флаги *Required
// переключают критерий между «обязательно» и «желательно».
type Prefs struct {
	Age          Range    `json:"age"`                     // всегда обязательный
	Genders      []string `json:"genders,omitempty"`       // обязательный, если задан
	VerifiedOnly bool     `json:"verified_only,omitempty"` // только с проверенным фото
	MinShared    int      `json:"min_shared,omitempty"`    // минимум точно совпадающих интересов

	Interests         []string `json:"interests,omitempty"`
	InterestsRequired bool     `json:"interests_required,omitempty"`

	Height         Range `json:"height"`
	HeightRequired bool  `json:"height_required,omitempty"`
	Weight         Range `json:"weight"`
	WeightRequired bool  `json:"weight_required,omitempty"`

	Habits         map[string][]string `json:"habits,omitempty"` // {"smoking": ["no"]}
	HabitsRequired bool                `json:"habits_required,omitempty"`

	Diets          []string `json:"diets,omitempty"`
	DietRequired   bool     `json:"diet_required,omitempty"`
	Zodiacs        []string `json:"zodiacs,omitempty"`
	ZodiacRequired bool     `json:"zodiac_required,omitempty"`

	Religions        []string `json:"religions,omitempty"` // учитываются только у тех, кто разрешил
	ReligionRequired bool     `json:"religion_required,omitempty"`
}

// ErrPhysicalNotAllowed — рост и вес можно задавать только в романтических целях.
var ErrPhysicalNotAllowed = errors.New("matching: физические параметры доступны только в целях «Романтика» и «Без обязательств»")

// Validate проверяет, что фильтры допустимы для цели.
func (p Prefs) Validate(g Goal) error {
	if !g.AllowsPhysical() && (!p.Height.IsZero() || !p.Weight.IsZero()) {
		return ErrPhysicalNotAllowed
	}
	if !p.Age.IsZero() && (p.Age.Min < 18 || (p.Age.Max != 0 && p.Age.Max < p.Age.Min)) {
		return fmt.Errorf("matching: некорректный возраст %d–%d", p.Age.Min, p.Age.Max)
	}
	return nil
}

// Profile — данные пользователя, нужные для подбора.
type Profile struct {
	ID        string
	Age       int
	Gender    string
	Goals     []Goal
	Interests []UserInterest

	HeightCm, WeightKg int // 0 — не указано
	Habits             map[string]string
	Diet, Zodiac       string

	Religion            string
	ReligionForMatching bool // разрешил использовать религию в подборе

	PhotoVerified bool
	AgeVerified   bool // 18+ подтверждено через Госуслуги

	LastActive   time.Time
	ResponseRate float64 // доля ответов на первые сообщения, 0–1

	Prefs map[Goal]Prefs
}

func (p Profile) hasGoal(g Goal) bool { return slices.Contains(p.Goals, g) }

// Eligible — проходит ли пара обязательные условия для цели с обеих сторон.
// reason объясняет отказ (для логов и тестов, не для пользователей).
func Eligible(a, b Profile, g Goal) (ok bool, reason string) {
	if a.ID == b.ID {
		return false, "это один и тот же пользователь"
	}
	if !a.hasGoal(g) || !b.hasGoal(g) {
		return false, "цель включена не у обоих"
	}
	if g == Casual && !(a.PhotoVerified && a.AgeVerified && b.PhotoVerified && b.AgeVerified) {
		return false, "для «Без обязательств» нужны проверенное фото и возраст через Госуслуги у обоих"
	}
	if why := failsRequired(a, b, g); why != "" {
		return false, "не подходит под фильтры " + a.ID + ": " + why
	}
	if why := failsRequired(b, a, g); why != "" {
		return false, "не подходит под фильтры " + b.ID + ": " + why
	}
	return true, ""
}

// criterion — результат проверки одного критерия.
type criterion struct {
	name     string
	required bool
	known    bool // у кандидата есть данные для проверки
	ok       bool
}

// criteria проверяет кандидата c по фильтрам смотрящего v для цели g.
func criteria(v, c Profile, g Goal) []criterion {
	p := v.Prefs[g]
	var out []criterion
	add := func(name string, required, known, ok bool) {
		out = append(out, criterion{name, required, known, ok})
	}
	if !p.Age.IsZero() {
		add("возраст", true, c.Age > 0, p.Age.Contains(c.Age))
	}
	if len(p.Genders) > 0 {
		add("пол", true, c.Gender != "", slices.Contains(p.Genders, c.Gender))
	}
	if p.VerifiedOnly {
		add("проверенное фото", true, true, c.PhotoVerified)
	}
	if p.MinShared > 0 {
		add("общие интересы", true, true, exactShared(v, c) >= p.MinShared)
	}
	if len(p.Interests) > 0 {
		has := false
		for _, ui := range c.Interests {
			if slices.Contains(p.Interests, ui.ID) {
				has = true
				break
			}
		}
		add("интересы", p.InterestsRequired, true, has)
	}
	if g.AllowsPhysical() {
		if !p.Height.IsZero() {
			add("рост", p.HeightRequired, c.HeightCm > 0, p.Height.Contains(c.HeightCm))
		}
		if !p.Weight.IsZero() {
			add("вес", p.WeightRequired, c.WeightKg > 0, p.Weight.Contains(c.WeightKg))
		}
	}
	keys := make([]string, 0, len(p.Habits))
	for k := range p.Habits {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		val, known := c.Habits[k]
		add("привычка "+k, p.HabitsRequired, known, slices.Contains(p.Habits[k], val))
	}
	if len(p.Diets) > 0 {
		add("питание", p.DietRequired, c.Diet != "", slices.Contains(p.Diets, c.Diet))
	}
	if len(p.Zodiacs) > 0 {
		add("знак зодиака", p.ZodiacRequired, c.Zodiac != "", slices.Contains(p.Zodiacs, c.Zodiac))
	}
	if len(p.Religions) > 0 {
		known := c.ReligionForMatching && c.Religion != ""
		add("религия", p.ReligionRequired, known, known && slices.Contains(p.Religions, c.Religion))
	}
	return out
}

// failsRequired возвращает первый невыполненный обязательный критерий.
// Неизвестное значение обязательный критерий не проходит.
func failsRequired(v, c Profile, g Goal) string {
	for _, cr := range criteria(v, c, g) {
		if cr.required && !(cr.known && cr.ok) {
			return cr.name
		}
	}
	return ""
}

// desiredFraction — доля выполненных желательных критериев; неизвестное
// значение засчитывается наполовину. Нет желательных критериев — 1.
func desiredFraction(v, c Profile, g Goal) float64 {
	total, got := 0.0, 0.0
	for _, cr := range criteria(v, c, g) {
		if cr.required {
			continue
		}
		total++
		switch {
		case !cr.known:
			got += 0.5
		case cr.ok:
			got++
		}
	}
	if total == 0 {
		return 1
	}
	return got / total
}

func exactShared(a, b Profile) int {
	n := 0
	for _, x := range a.Interests {
		for _, y := range b.Interests {
			if x.ID == y.ID {
				n++
				break
			}
		}
	}
	return n
}

// Catalog — то, что подбору нужно от каталога интересов.
type Catalog interface {
	Similarity(a, b string) float64
	Name(id string) string
}

// Weights — веса компонентов оценки (ТЗ: 0.5 / 0.25 / 0.15 / 0.1).
type Weights struct{ Interests, Prefs, Habits, Activity float64 }

// DefaultWeights — стартовые веса MVP; калибруются после запуска.
var DefaultWeights = Weights{Interests: 0.5, Prefs: 0.25, Habits: 0.15, Activity: 0.1}

// Scorer считает оценку совместимости.
type Scorer struct {
	Catalog    Catalog
	Popularity func(interestID string) int // сколько людей указали интерес
	Weights    Weights
	Now        func() time.Time
}

// SharedInterest — точно совпавший интерес.
type SharedInterest struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Rare bool   `json:"rare"`
}

// Result — оценка для карточки кандидата.
type Result struct {
	Score       int // 0–100
	Shared      []SharedInterest
	Explanation string // «5 общих интересов, включая бонсай и эндуро»
	Icebreaker  string // подсказка для первого сообщения
}

// RarePopularity — интерес считается редким, если его указали меньше людей.
const RarePopularity = 200

// Score — насколько кандидат c подходит смотрящему v в цели g.
// Вызывать только для пар, прошедших Eligible.
func (s Scorer) Score(v, c Profile, g Goal) Result {
	w := s.Weights
	if w == (Weights{}) {
		w = DefaultWeights
	}
	i := (s.interestSim(v, c) + s.interestSim(c, v)) / 2
	p := (desiredFraction(v, c, g) + desiredFraction(c, v, g)) / 2
	h := habitSim(v, c)
	a := s.activity(c)
	score := 100 * (w.Interests*i + w.Prefs*p + w.Habits*h + w.Activity*a)

	shared := s.shared(v, c)
	return Result{
		Score:       int(math.Round(math.Max(0, math.Min(100, score)))),
		Shared:      shared,
		Explanation: explain(shared),
		Icebreaker:  icebreaker(shared),
	}
}

// rarity — вес интереса: чем меньше людей его указали, тем больше вес.
func (s Scorer) rarity(id string) float64 {
	pop := 0
	if s.Popularity != nil {
		pop = s.Popularity(id)
	}
	return 1 / math.Log(math.E+float64(pop))
}

// interestSim — направленное сходство интересов a к интересам b.
func (s Scorer) interestSim(a, b Profile) float64 {
	if len(a.Interests) == 0 || len(b.Interests) == 0 {
		return 0
	}
	sum, total := 0.0, 0.0
	for _, x := range a.Interests {
		best := 0.0
		for _, y := range b.Interests {
			best = math.Max(best, s.Catalog.Similarity(x.ID, y.ID))
		}
		weight := s.rarity(x.ID)
		if x.SeekingPartner {
			weight *= 2
		}
		sum += weight * best
		total += weight
	}
	return sum / total
}

func habitSim(a, b Profile) float64 {
	common, equal := 0, 0
	for k, va := range a.Habits {
		if vb, ok := b.Habits[k]; ok {
			common++
			if va == vb {
				equal++
			}
		}
	}
	if common == 0 {
		return 0.5
	}
	return float64(equal) / float64(common)
}

func (s Scorer) activity(c Profile) float64 {
	now := time.Now()
	if s.Now != nil {
		now = s.Now()
	}
	days := now.Sub(c.LastActive).Hours() / 24
	if days < 0 {
		days = 0
	}
	rr := math.Max(0, math.Min(1, c.ResponseRate))
	return 0.7*math.Exp(-days/7) + 0.3*rr
}

func (s Scorer) shared(v, c Profile) []SharedInterest {
	var out []SharedInterest
	pops := map[string]int{}
	for _, x := range v.Interests {
		for _, y := range c.Interests {
			if x.ID != y.ID {
				continue
			}
			pop := 0
			if s.Popularity != nil {
				pop = s.Popularity(x.ID)
			}
			pops[x.ID] = pop
			out = append(out, SharedInterest{ID: x.ID, Name: s.Catalog.Name(x.ID), Rare: pop < RarePopularity})
			break
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return pops[out[i].ID] < pops[out[j].ID] })
	return out
}

func explain(shared []SharedInterest) string {
	n := len(shared)
	switch n {
	case 0:
		return "Похожие увлечения"
	case 1:
		return "Общий интерес: " + lowerFirst(shared[0].Name)
	}
	return fmt.Sprintf("%d %s, включая %s и %s", n, plural(n, "общий интерес", "общих интереса", "общих интересов"),
		lowerFirst(shared[0].Name), lowerFirst(shared[1].Name))
}

func icebreaker(shared []SharedInterest) string {
	if len(shared) == 0 {
		return "Расскажите, чем увлекаетесь, и спросите о любимом занятии собеседника."
	}
	return fmt.Sprintf("Вас объединяет %s. Спросите, с чего у собеседника всё началось.", lowerFirst(shared[0].Name))
}

// plural — русское склонение по числу: 1 интерес, 2 интереса, 5 интересов.
func plural(n int, one, few, many string) string {
	n10, n100 := n%10, n%100
	switch {
	case n10 == 1 && n100 != 11:
		return one
	case n10 >= 2 && n10 <= 4 && (n100 < 12 || n100 > 14):
		return few
	default:
		return many
	}
}

// lowerFirst делает первую букву строчной, кроме аббревиатур («ММА», «Off-road» оставляем).
func lowerFirst(s string) string {
	r, size := utf8.DecodeRuneInString(s)
	if size == 0 {
		return s
	}
	next, _ := utf8.DecodeRuneInString(s[size:])
	if unicode.IsUpper(next) || !unicode.Is(unicode.Cyrillic, r) {
		return s
	}
	return strings.ToLower(string(r)) + s[size:]
}

// AllGoals — все цели знакомства.
var AllGoals = []Goal{Romance, Casual, Friendship, Hobby, Talk, Travel, LikeMinded}

// Valid — известна ли цель.
func (g Goal) Valid() bool { return slices.Contains(AllGoals, g) }

// ValidLevel — известен ли уровень вовлечённости.
func ValidLevel(l Level) bool {
	return l == Curious || l == Doing || l == Serious || l == Pro || l == WantToLearn
}
