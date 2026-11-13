package feed

import (
	"context"
	"encoding/hex"
	"errors"
	"os"
	"slices"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/catalog"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/contacts"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/matching"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/profile"
	"github.com/stepamolotok-star/interest-dating-app/backend/migrations"
)

var clock = time.Date(2026, 11, 12, 12, 0, 0, 0, time.UTC)

type env struct {
	db   *pgxpool.Pool
	prof *profile.Service
	feed *Service
	n    int
}

func setup(t *testing.T) *env {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("TEST_DATABASE_URL не задан — пропускаю тесты с базой")
	}
	ctx := context.Background()
	db, err := pgxpool.New(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	if _, err := migrations.Apply(ctx, db); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(ctx, `TRUNCATE users CASCADE`); err != nil {
		t.Fatal(err)
	}
	cat, _ := catalog.Default()
	prof := &profile.Service{DB: db, Catalog: cat}
	if err := prof.SyncCatalog(ctx); err != nil {
		t.Fatal(err)
	}
	return &env{db: db, prof: prof, feed: &Service{DB: db, Catalog: cat, Now: func() time.Time { return clock }}}
}

type person struct {
	gender, city string
	age          int
	goals        []matching.Goal
	interests    []string
	verified     bool
}

func (e *env) user(t *testing.T, p person) string {
	t.Helper()
	ctx := context.Background()
	e.n++
	if p.city == "" {
		p.city = "Чита"
	}
	if p.gender == "" {
		p.gender = "female"
	}
	if p.age == 0 {
		p.age = 30
	}
	var verified *time.Time
	if p.verified {
		verified = &clock
	}
	var id string
	err := e.db.QueryRow(ctx, `INSERT INTO users (phone_e164, birth_date, gender, photo_verified_at, gosuslugi_verified_at, last_active_at)
		VALUES ($1, $2, $3, $4, $4, $5) RETURNING id`,
		"+7914000"+string(rune('0'+e.n/1000%10))+string(rune('0'+e.n/100%10))+string(rune('0'+e.n/10%10))+string(rune('0'+e.n%10)),
		clock.AddDate(-p.age, -1, 0), p.gender, verified, clock).Scan(&id)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.db.Exec(ctx, `INSERT INTO profiles (user_id, display_name, city, about) VALUES ($1, 'Тест', $2, 'Люблю дорогу')`, id, p.city); err != nil {
		t.Fatal(err)
	}
	var goals []profile.GoalSetting
	for _, g := range p.goals {
		goals = append(goals, profile.GoalSetting{Goal: g, Active: true})
	}
	if err := e.prof.SetGoals(ctx, id, goals); err != nil {
		t.Fatal(err)
	}
	if len(p.interests) > 0 {
		var items []profile.Interest
		for _, i := range p.interests {
			items = append(items, profile.Interest{ID: i, Level: matching.Doing})
		}
		if err := e.prof.SetInterests(ctx, id, items); err != nil {
			t.Fatal(err)
		}
	}
	return id
}

const (
	bonsai = "home.garden.bonsai"
	enduro = "transport.moto.enduro"
	movies = "screen_books.cinema.movies"
)

func ids(cards []Card) []string {
	out := make([]string, len(cards))
	for i, c := range cards {
		out[i] = c.UserID
	}
	return out
}

func TestFeedRanksAndFilters(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	hobby := []matching.Goal{matching.Hobby}

	viewer := e.user(t, person{goals: hobby, interests: []string{bonsai, enduro}})
	best := e.user(t, person{goals: hobby, interests: []string{bonsai, enduro}})
	weak := e.user(t, person{goals: hobby, interests: []string{movies}})
	otherGoal := e.user(t, person{goals: []matching.Goal{matching.Friendship}, interests: []string{bonsai}})
	otherCity := e.user(t, person{goals: hobby, city: "Иркутск", interests: []string{bonsai}})
	// Массовый интерес «кино» — у многих.
	for i := 0; i < 3; i++ {
		e.user(t, person{goals: []matching.Goal{matching.Talk}, interests: []string{movies}})
	}

	cards, err := e.feed.Feed(ctx, viewer, matching.Hobby, 10)
	if err != nil {
		t.Fatal(err)
	}
	got := ids(cards)
	if len(got) != 2 || got[0] != best || got[1] != weak {
		t.Fatalf("лента: %v, ждали [%s %s]; другая цель %s и другой город %s не должны попасть", got, best, weak, otherGoal, otherCity)
	}
	c := cards[0]
	if c.AgeRange != "28–32" || c.Age < 28 || c.Age > 32 || len(c.Shared) != 2 || c.About != "Люблю дорогу" || c.OtherInterest != 0 {
		t.Fatalf("карточка: %+v", c)
	}
	// Кто попросил показывать возраст диапазоном — точного возраста в карточке нет.
	if _, err := e.db.Exec(ctx, `UPDATE profiles SET age_as_range = true WHERE user_id = $1`, best); err != nil {
		t.Fatal(err)
	}
	if again, _ := e.feed.Feed(ctx, viewer, matching.Hobby, 10); again[0].Age != 0 || again[0].AgeRange != "28–32" {
		t.Fatalf("возраст диапазоном: %+v", again[0])
	}
	// У «слабого» общих интересов нет — его интересы видны списком, а не только числом.
	if w := cards[1]; w.OtherInterest != 1 || len(w.Others) != 1 || w.Others[0] == "" {
		t.Fatalf("остальные интересы: %+v", w)
	}
	if _, err := e.feed.Feed(ctx, viewer, matching.Romance, 10); !errors.Is(err, ErrGoalNotActive) {
		t.Fatalf("лента по невключённой цели: %v", err)
	}
}

func TestMutualPrefsAndVisibility(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	fr := []matching.Goal{matching.Friendship}
	viewer := e.user(t, person{goals: fr, age: 30, interests: []string{bonsai}})
	older := e.user(t, person{goals: fr, age: 45, interests: []string{bonsai}})
	picky := e.user(t, person{goals: fr, age: 31, interests: []string{bonsai}})

	if err := e.prof.SetPrefs(ctx, viewer, matching.Friendship, matching.Prefs{Age: matching.Range{Min: 25, Max: 40}}); err != nil {
		t.Fatal(err)
	}
	// picky ищет только 18–25 — viewer (30) ему не подходит, значит пары нет в обе стороны.
	if err := e.prof.SetPrefs(ctx, picky, matching.Friendship, matching.Prefs{Age: matching.Range{Min: 18, Max: 25}}); err != nil {
		t.Fatal(err)
	}
	cards, err := e.feed.Feed(ctx, viewer, matching.Friendship, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(cards) != 0 {
		t.Fatalf("старше фильтра (%s) и не подходящий под фильтр второй стороны (%s) — пусто, получили %v", older, picky, ids(cards))
	}

	// «О себе» скрыто — в карточке его нет.
	nice := e.user(t, person{goals: fr, age: 29, interests: []string{bonsai}})
	if err := e.prof.SetVisibility(ctx, nice, map[string]string{"about": profile.AfterMatch}); err != nil {
		t.Fatal(err)
	}
	cards, _ = e.feed.Feed(ctx, viewer, matching.Friendship, 10)
	if len(cards) != 1 || cards[0].About != "" {
		t.Fatalf("«о себе» после совпадения не должно быть в анонимной карточке: %+v", cards)
	}
}

func TestInterestMatchSkipBlock(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	h := []matching.Goal{matching.Hobby}
	anna := e.user(t, person{goals: h, interests: []string{bonsai, enduro}})
	igor := e.user(t, person{goals: h, gender: "male", interests: []string{enduro}})
	lena := e.user(t, person{goals: h, interests: []string{enduro}})
	oleg := e.user(t, person{goals: h, gender: "male", interests: []string{enduro}})

	if _, err := e.feed.Interest(ctx, anna, igor, matching.Hobby, bonsai); err == nil {
		t.Fatal("бонсай не общий интерес — отметить нельзя")
	}
	res, err := e.feed.Interest(ctx, anna, igor, matching.Hobby, enduro)
	if err != nil || res.Matched {
		t.Fatalf("одностороннее «Интересно» не создаёт совпадение: %+v %v", res, err)
	}
	res, err = e.feed.Interest(ctx, igor, anna, matching.Hobby, "")
	if err != nil || !res.Matched || res.MatchID == "" {
		t.Fatalf("взаимное «Интересно»: %+v %v", res, err)
	}
	var left int
	if err := e.db.QueryRow(ctx, `SELECT count(*) FROM interests_expressed`).Scan(&left); err != nil || left != 0 {
		t.Fatalf("после совпадения односторонние отметки удаляются: %d %v", left, err)
	}
	cards, _ := e.feed.Feed(ctx, anna, matching.Hobby, 10)
	for _, c := range cards {
		if c.UserID == igor {
			t.Fatal("совпавший человек не показывается в ленте")
		}
	}

	if err := e.feed.Skip(ctx, anna, lena, matching.Hobby); err != nil {
		t.Fatal(err)
	}
	if _, err := e.db.Exec(ctx, `INSERT INTO blocks (blocker, blocked) VALUES ($1, $2)`, oleg, anna); err != nil {
		t.Fatal(err)
	}
	cards, _ = e.feed.Feed(ctx, anna, matching.Hobby, 10)
	if len(cards) != 0 {
		t.Fatalf("пропущенная и заблокировавший не показываются: %v", ids(cards))
	}
	if _, err := e.feed.Interest(ctx, anna, oleg, matching.Hobby, ""); !errors.Is(err, ErrNotAvailable) {
		t.Fatalf("«Интересно» тому, кто заблокировал: %v", err)
	}
}

func TestCasualRequiresVerification(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	plain := e.user(t, person{goals: []matching.Goal{matching.Friendship}})
	err := e.prof.SetGoals(ctx, plain, []profile.GoalSetting{{Goal: matching.Casual, Active: true}})
	if !errors.Is(err, profile.ErrNeedVerification) {
		t.Fatalf("без Госуслуг: %v", err)
	}
	ok := e.user(t, person{goals: []matching.Goal{matching.Casual}, verified: true})
	if ok == "" {
		t.Fatal("с подтверждением цель включается")
	}
}

func TestProfileRules(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	id := e.user(t, person{goals: []matching.Goal{matching.Hobby}})
	if err := e.prof.SetPrefs(ctx, id, matching.Hobby, matching.Prefs{Height: matching.Range{Min: 170}}); err == nil {
		t.Fatal("рост в фильтрах «Хобби» недопустим")
	}
	f := profile.Fields{Religion: "orthodox"}
	if err := e.prof.Update(ctx, id, f, false, "v1"); !errors.Is(err, profile.ErrNeedSpecialConsent) {
		t.Fatalf("религия без отдельного согласия: %v", err)
	}
	if err := e.prof.Update(ctx, id, f, true, "v1"); err != nil {
		t.Fatalf("с согласием: %v", err)
	}
	got, err := e.prof.Get(ctx, id)
	if err != nil || got.Religion != "orthodox" {
		t.Fatalf("Get: %+v %v", got, err)
	}
	if err := e.prof.Update(ctx, id, profile.Fields{Habits: map[string]string{"smoking": "много"}}, false, "v1"); err == nil {
		t.Fatal("недопустимое значение привычки")
	}
	if err := e.prof.SetInterests(ctx, id, []profile.Interest{{ID: "transport.moto", Level: matching.Doing}}); err == nil {
		t.Fatal("подкатегорию нельзя выбрать как увлечение")
	}
}

func TestAgeRangeAndZodiac(t *testing.T) {
	cases := map[int]string{18: "18–22", 22: "18–22", 23: "23–27", 30: "28–32", 47: "43–47"}
	for age, want := range cases {
		if got := AgeRange(age); got != want {
			t.Errorf("AgeRange(%d) = %s, ждали %s", age, got, want)
		}
	}
	if Zodiac(time.Date(1994, 3, 14, 0, 0, 0, 0, time.UTC)) != "pisces" ||
		Zodiac(time.Date(1990, 12, 25, 0, 0, 0, 0, time.UTC)) != "capricorn" ||
		Zodiac(time.Date(1990, 1, 10, 0, 0, 0, 0, time.UTC)) != "capricorn" {
		t.Error("Zodiac")
	}
}

func TestHideFromContacts(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	anna := e.user(t, person{goals: []matching.Goal{matching.Friendship}, interests: []string{bonsai}})
	igor := e.user(t, person{gender: "male", goals: []matching.Goal{matching.Friendship}, interests: []string{bonsai}})
	c := &contacts.Service{DB: e.db, Secret: []byte("test-secret")}
	if _, err := c.Backfill(ctx); err != nil {
		t.Fatal(err)
	}
	var annaPhone string
	if err := e.db.QueryRow(ctx, `SELECT phone_e164 FROM users WHERE id = $1`, anna).Scan(&annaPhone); err != nil {
		t.Fatal(err)
	}
	sees := func(viewer, target string) bool {
		t.Helper()
		cards, err := e.feed.Feed(ctx, viewer, matching.Friendship, 20)
		if err != nil {
			t.Fatal(err)
		}
		return slices.Contains(ids(cards), target)
	}
	if !sees(anna, igor) {
		t.Fatal("до загрузки контактов Анна должна видеть Игоря")
	}

	// Игорь прячется от своей записной книжки, где есть Анна.
	other := hex.EncodeToString(contacts.PhoneHash("+79990000000"))
	st, err := c.Upload(ctx, igor, []string{hex.EncodeToString(contacts.PhoneHash(annaPhone)), other, other}, "test")
	if err != nil || st.Count != 2 || !st.Hide {
		t.Fatalf("загрузка: %+v %v", st, err)
	}
	if sees(anna, igor) {
		t.Fatal("Анна в контактах Игоря — не должна его видеть")
	}
	if !sees(igor, anna) {
		t.Fatal("скрытие одностороннее: Игорь видит Анну")
	}

	// В базе нет ни номера, ни голого SHA-256 — только HMAC.
	var raw int
	if err := e.db.QueryRow(ctx, `SELECT count(*) FROM contact_hashes WHERE phone_hash = $1`,
		contacts.PhoneHash(annaPhone)).Scan(&raw); err != nil || raw != 0 {
		t.Fatalf("голый хэш номера не должен храниться: %d %v", raw, err)
	}

	if err := c.Clear(ctx, igor); err != nil {
		t.Fatal(err)
	}
	if !sees(anna, igor) {
		t.Fatal("после отключения Анна снова видит Игоря")
	}
	if st, _ := c.Get(ctx, igor); st.Count != 0 || st.Hide {
		t.Fatalf("после отключения всё удалено: %+v", st)
	}
	if _, err := c.Upload(ctx, igor, []string{"не-хэш"}, "test"); err == nil {
		t.Fatal("мусор вместо хэша должен отклоняться")
	}
}
