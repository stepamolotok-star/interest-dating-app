package matching

import (
	"strings"
	"testing"
	"time"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/catalog"
)

var now = time.Date(2026, 11, 12, 12, 0, 0, 0, time.UTC)

func scorer(t *testing.T) Scorer {
	t.Helper()
	cat, err := catalog.Default()
	if err != nil {
		t.Fatal(err)
	}
	pop := map[string]int{
		"home.garden.bonsai":         40, // редкий
		"transport.moto.enduro":      900,
		"home.garden.gardening":      5000,
		"screen_books.cinema.movies": 20000, // массовый
	}
	return Scorer{Catalog: cat, Popularity: func(id string) int { return pop[id] }, Now: func() time.Time { return now }}
}

func person(id string, goals []Goal, interests ...string) Profile {
	p := Profile{ID: id, Age: 30, Gender: "female", Goals: goals, LastActive: now, ResponseRate: 0.8,
		Habits: map[string]string{"smoking": "no"}, Prefs: map[Goal]Prefs{}}
	for _, i := range interests {
		p.Interests = append(p.Interests, UserInterest{ID: i, Level: Doing})
	}
	return p
}

func TestEligibleRequiresSameGoal(t *testing.T) {
	a := person("a", []Goal{Friendship}, "home.garden.bonsai")
	b := person("b", []Goal{Romance}, "home.garden.bonsai")
	if ok, _ := Eligible(a, b, Friendship); ok {
		t.Fatal("человек без цели «Дружба» не должен попадать в дружескую выдачу")
	}
	b.Goals = append(b.Goals, Friendship)
	if ok, why := Eligible(a, b, Friendship); !ok {
		t.Fatalf("должны подходить: %s", why)
	}
	if ok, _ := Eligible(a, a, Friendship); ok {
		t.Fatal("сам с собой")
	}
}

func TestCasualNeedsGosuslugiAndPhoto(t *testing.T) {
	a := person("a", []Goal{Casual})
	b := person("b", []Goal{Casual})
	a.PhotoVerified, b.PhotoVerified = true, true
	a.AgeVerified = true
	if ok, _ := Eligible(a, b, Casual); ok {
		t.Fatal("без подтверждения возраста у b цель недоступна")
	}
	b.AgeVerified = true
	if ok, why := Eligible(a, b, Casual); !ok {
		t.Fatalf("оба подтверждены: %s", why)
	}
}

func TestFiltersAreMutual(t *testing.T) {
	a := person("a", []Goal{Romance})
	b := person("b", []Goal{Romance})
	b.Gender = "male"
	a.Prefs[Romance] = Prefs{Age: Range{25, 35}, Genders: []string{"male"}}
	b.Prefs[Romance] = Prefs{Age: Range{18, 25}, Genders: []string{"female"}} // a старше
	if ok, why := Eligible(a, b, Romance); ok {
		t.Fatal("a не проходит фильтр возраста b — пары быть не должно")
	} else if !strings.Contains(why, "возраст") {
		t.Fatalf("причина: %s", why)
	}
	b.Prefs[Romance] = Prefs{Age: Range{25, 40}, Genders: []string{"female"}}
	if ok, why := Eligible(a, b, Romance); !ok {
		t.Fatalf("теперь подходят: %s", why)
	}
}

func TestRequiredUnknownFails_DesiredUnknownHalf(t *testing.T) {
	a := person("a", []Goal{Romance})
	b := person("b", []Goal{Romance}) // рост не указан
	a.Prefs[Romance] = Prefs{Height: Range{170, 190}, HeightRequired: true}
	if ok, _ := Eligible(a, b, Romance); ok {
		t.Fatal("обязательный рост неизвестен — не проходит")
	}
	a.Prefs[Romance] = Prefs{Height: Range{170, 190}}
	if ok, _ := Eligible(a, b, Romance); !ok {
		t.Fatal("желательный критерий не отсекает")
	}
	if got := desiredFraction(a, b, Romance); got != 0.5 {
		t.Fatalf("неизвестное желательное = 0.5, получили %v", got)
	}
}

func TestReligionOnlyWithPermission(t *testing.T) {
	a := person("a", []Goal{Friendship})
	b := person("b", []Goal{Friendship})
	b.Religion = "orthodox"
	a.Prefs[Friendship] = Prefs{Religions: []string{"orthodox"}, ReligionRequired: true}
	if ok, _ := Eligible(a, b, Friendship); ok {
		t.Fatal("религия без разрешения b не должна использоваться")
	}
	b.ReligionForMatching = true
	if ok, why := Eligible(a, b, Friendship); !ok {
		t.Fatalf("с разрешением: %s", why)
	}
}

func TestPhysicalPrefsOnlyInRomanticGoals(t *testing.T) {
	p := Prefs{Height: Range{170, 0}}
	if err := p.Validate(Hobby); err != ErrPhysicalNotAllowed {
		t.Fatalf("для «Хобби» ждали ErrPhysicalNotAllowed, получили %v", err)
	}
	if err := p.Validate(Casual); err != nil {
		t.Fatalf("для «Без обязательств» допустимо: %v", err)
	}
	if err := (Prefs{Age: Range{16, 30}}).Validate(Friendship); err == nil {
		t.Fatal("возраст младше 18 недопустим")
	}
}

func TestRareSharedInterestScoresHigher(t *testing.T) {
	s := scorer(t)
	viewer := person("v", []Goal{Hobby}, "home.garden.bonsai", "screen_books.cinema.movies")
	rare := person("r", []Goal{Hobby}, "home.garden.bonsai")
	common := person("c", []Goal{Hobby}, "screen_books.cinema.movies")

	rs, cs := s.Score(viewer, rare, Hobby), s.Score(viewer, common, Hobby)
	if rs.Score <= cs.Score {
		t.Fatalf("общий редкий интерес должен весить больше: бонсай %d, кино %d", rs.Score, cs.Score)
	}
	if !rs.Shared[0].Rare || cs.Shared[0].Rare {
		t.Fatalf("метки редкости: %+v / %+v", rs.Shared, cs.Shared)
	}
}

func TestPartialMatchBySubcategory(t *testing.T) {
	s := scorer(t)
	v := person("v", []Goal{Hobby}, "transport.moto.enduro")
	near := person("n", []Goal{Hobby}, "transport.moto.moto_touring")
	none := person("x", []Goal{Hobby}, "music.listen.jazz")
	if a, b := s.Score(v, near, Hobby).Score, s.Score(v, none, Hobby).Score; a <= b {
		t.Fatalf("мототуризм ближе к эндуро, чем джаз: %d vs %d", a, b)
	}
}

func TestInactiveRanksLower(t *testing.T) {
	s := scorer(t)
	v := person("v", []Goal{Friendship}, "home.garden.bonsai")
	active := person("a", []Goal{Friendship}, "home.garden.bonsai")
	stale := active
	stale.ID = "s"
	stale.LastActive = now.Add(-60 * 24 * time.Hour)
	if a, b := s.Score(v, active, Friendship).Score, s.Score(v, stale, Friendship).Score; a <= b {
		t.Fatalf("заброшенная анкета должна быть ниже: %d vs %d", a, b)
	}
}

func TestExplanationAndIcebreaker(t *testing.T) {
	s := scorer(t)
	v := person("v", []Goal{Hobby}, "home.garden.bonsai", "transport.moto.enduro", "home.garden.gardening")
	c := person("c", []Goal{Hobby}, "transport.moto.enduro", "home.garden.bonsai", "home.garden.gardening")
	r := s.Score(v, c, Hobby)
	if r.Explanation != "3 общих интереса: бонсай, эндуро, садоводство" {
		t.Fatalf("объяснение: %q", r.Explanation)
	}
	if !strings.Contains(r.Icebreaker, "бонсай") {
		t.Fatalf("подсказка должна строиться на самом редком интересе: %q", r.Icebreaker)
	}
	if r.Score < 0 || r.Score > 100 {
		t.Fatalf("оценка вне 0–100: %d", r.Score)
	}
}

func TestPlural(t *testing.T) {
	cases := map[int]string{1: "интерес", 2: "интереса", 5: "интересов", 11: "интересов", 21: "интерес", 22: "интереса", 112: "интересов"}
	for n, want := range cases {
		if got := plural(n, "интерес", "интереса", "интересов"); got != want {
			t.Errorf("plural(%d) = %s, ждали %s", n, got, want)
		}
	}
	if lowerFirst("ММА") != "ММА" || lowerFirst("Эндуро") != "эндуро" || lowerFirst("Off-road") != "Off-road" {
		t.Error("lowerFirst")
	}
}
