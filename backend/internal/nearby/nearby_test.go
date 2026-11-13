package nearby

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/catalog"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/feed"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/matching"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/profile"
	"github.com/stepamolotok-star/interest-dating-app/backend/migrations"
)

// Точки в Чите: base и в ~300 м, ~800 м, ~2 км, ~100 км.
const (
	baseLat, baseLon = 52.0337, 113.4994
)

var (
	near300 = [2]float64{52.0362, 113.5010}
	near800 = [2]float64{52.0400, 113.5060}
	far2km  = [2]float64{52.0337, 113.5290}
	far100k = [2]float64{52.9337, 113.4994}
)

type fakePush struct{ msgs []string }

func (f *fakePush) Push(_ context.Context, userID, title, body string) error {
	f.msgs = append(f.msgs, body)
	return nil
}

type env struct {
	db    *pgxpool.Pool
	prof  *profile.Service
	svc   *Service
	push  *fakePush
	clock *time.Time
	n     int
}

func setup(t *testing.T) *env {
	t.Helper()
	dbURL, rURL := os.Getenv("TEST_DATABASE_URL"), os.Getenv("TEST_REDIS_URL")
	if dbURL == "" || rURL == "" {
		t.Skip("нужны TEST_DATABASE_URL и TEST_REDIS_URL")
	}
	ctx := context.Background()
	db, err := pgxpool.New(ctx, dbURL)
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
	opt, _ := redis.ParseURL(rURL)
	rdb := redis.NewClient(opt)
	t.Cleanup(func() { rdb.Close() })
	if err := rdb.FlushDB(ctx).Err(); err != nil {
		t.Fatal(err)
	}
	cat, _ := catalog.Default()
	prof := &profile.Service{DB: db, Catalog: cat}
	if err := prof.SyncCatalog(ctx); err != nil {
		t.Fatal(err)
	}
	clock := time.Date(2026, 11, 12, 3, 0, 0, 0, time.UTC) // 12:00 по Чите
	now := func() time.Time { return clock }
	push := &fakePush{}
	fs := &feed.Service{DB: db, Catalog: cat, Now: now}
	return &env{db: db, prof: prof, push: push, clock: &clock,
		svc: &Service{DB: db, Redis: rdb, Feed: fs, Push: push, Now: now}}
}

func (e *env) user(t *testing.T, goal matching.Goal, verified bool) string {
	t.Helper()
	ctx := context.Background()
	e.n++
	var ver *time.Time
	if verified {
		ver = e.clock
	}
	var id string
	if err := e.db.QueryRow(ctx, `INSERT INTO users (phone_e164, birth_date, gender, photo_verified_at, gosuslugi_verified_at)
		VALUES ($1, '1996-01-01', 'female', $2, $2) RETURNING id`, fmt.Sprintf("+7914%07d", e.n), ver).Scan(&id); err != nil {
		t.Fatal(err)
	}
	if _, err := e.db.Exec(ctx, `INSERT INTO profiles (user_id, display_name, city, timezone) VALUES ($1, 'Тест', 'Чита', 'Asia/Chita')`, id); err != nil {
		t.Fatal(err)
	}
	if err := e.prof.SetGoals(ctx, id, []profile.GoalSetting{{Goal: goal, Active: true, NearbyVisible: true}}); err != nil {
		t.Fatal(err)
	}
	if err := e.prof.SetInterests(ctx, id, []profile.Interest{
		{ID: "transport.moto.enduro", Level: matching.Doing}, {ID: "home.garden.bonsai", Level: matching.Doing}}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.svc.SetVisibility(ctx, id, SetVisibilityInput{Mode: ModeTimed, Hours: 3, RadiusM: 1000}); err != nil {
		t.Fatal(err)
	}
	return id
}

func (e *env) at(t *testing.T, id string, p [2]float64) LocationStatus {
	t.Helper()
	st, err := e.svc.UpdateLocation(context.Background(), id, p[0], p[1], false)
	if err != nil {
		t.Fatalf("UpdateLocation: %v", err)
	}
	return st
}

func TestRadarBasicsAndSymmetry(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	me := e.user(t, matching.Hobby, false)
	her := e.user(t, matching.Hobby, false)
	e.at(t, me, [2]float64{baseLat, baseLon})
	e.at(t, her, near300)

	cards, err := e.svc.Radar(ctx, me, matching.Hobby)
	if err != nil || len(cards) != 1 || cards[0].UserID != her || cards[0].Distance != "до 500 м" || !cards[0].PhotosHidden {
		t.Fatalf("радар: %+v %v", cards, err)
	}
	if strings.Contains(fmt.Sprintf("%+v", cards[0]), "52.03") {
		t.Fatal("в карточке не должно быть координат")
	}

	// Невидимый не видит других.
	if err := e.svc.Disappear(ctx, me); err != nil {
		t.Fatal(err)
	}
	if _, err := e.svc.Radar(ctx, me, matching.Hobby); !errors.Is(err, ErrNotVisible) {
		t.Fatalf("исчезнувший смотрит радар: %v", err)
	}
	// И его не видят.
	if cards, _ := e.svc.Radar(ctx, her, matching.Hobby); len(cards) != 0 {
		t.Fatalf("исчезнувшего видно: %+v", cards)
	}
}

func TestPrivateZoneHides(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	me := e.user(t, matching.Hobby, false)
	her := e.user(t, matching.Hobby, false)
	e.at(t, me, [2]float64{baseLat, baseLon})
	e.at(t, her, near300)
	if _, err := e.svc.AddZone(ctx, her, "Дом", near300[0], near300[1], 500); err != nil {
		t.Fatal(err)
	}
	if cards, _ := e.svc.Radar(ctx, me, matching.Hobby); len(cards) != 0 {
		t.Fatal("человек в личной зоне должен исчезнуть сразу после её создания")
	}
	*e.clock = e.clock.Add(time.Minute)
	if st := e.at(t, her, near300); st.Visible || st.Reason != "private_zone" {
		t.Fatalf("в зоне: %+v", st)
	}
	if _, err := e.svc.AddZone(ctx, her, "Работа", 52, 113, 100); err == nil {
		t.Fatal("зона меньше 500 м недопустима")
	}
}

func TestRadiusVerifiedAndCasualPrecision(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	me := e.user(t, matching.Hobby, false)
	small := e.user(t, matching.Hobby, false)
	picky := e.user(t, matching.Hobby, false)
	e.at(t, me, [2]float64{baseLat, baseLon})
	e.at(t, small, near800)
	e.at(t, picky, near300)
	if _, err := e.svc.SetVisibility(ctx, small, SetVisibilityInput{Mode: ModeBackground, RadiusM: 300}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.svc.SetVisibility(ctx, picky, SetVisibilityInput{Mode: ModeBackground, RadiusM: 1000, VerifiedOnly: true}); err != nil {
		t.Fatal(err)
	}
	cards, err := e.svc.Radar(ctx, me, matching.Hobby)
	if err != nil || len(cards) != 0 {
		t.Fatalf("радиус 300 м у одного и «только проверенным» у другой — никого: %+v %v", cards, err)
	}

	a := e.user(t, matching.Casual, true)
	b := e.user(t, matching.Casual, true)
	e.at(t, a, [2]float64{baseLat, baseLon})
	e.at(t, b, near300)
	cards, err = e.svc.Radar(ctx, a, matching.Casual)
	if err != nil || len(cards) != 1 || cards[0].Distance != "до 1 км" {
		t.Fatalf("для «Без обязательств» точность не выше «до 1 км»: %+v %v", cards, err)
	}
}

func TestStableBucketAndRateLimit(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	me := e.user(t, matching.Hobby, false)
	her := e.user(t, matching.Hobby, false)
	if _, err := e.svc.SetVisibility(ctx, me, SetVisibilityInput{Mode: ModeBackground, RadiusM: 3000}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.svc.SetVisibility(ctx, her, SetVisibilityInput{Mode: ModeBackground, RadiusM: 3000}); err != nil {
		t.Fatal(err)
	}
	e.at(t, me, [2]float64{baseLat, baseLon})
	e.at(t, her, near300)
	if c, _ := e.svc.Radar(ctx, me, matching.Hobby); len(c) != 1 || c[0].Distance != "до 500 м" {
		t.Fatalf("сначала до 500 м: %+v", c)
	}
	*e.clock = e.clock.Add(2 * time.Minute)
	e.at(t, her, far2km)
	if c, _ := e.svc.Radar(ctx, me, matching.Hobby); len(c) != 1 || c[0].Distance != "до 500 м" {
		t.Fatalf("интервал для пары не меняется 15 минут: %+v", c)
	}
	for i := 0; i < RadarPerMinute-2; i++ {
		if _, err := e.svc.Radar(ctx, me, matching.Hobby); err != nil {
			t.Fatalf("запрос %d: %v", i+3, err)
		}
	}
	if _, err := e.svc.Radar(ctx, me, matching.Hobby); !errors.Is(err, ErrTooFrequent) {
		t.Fatalf("седьмой запрос в минуту: %v", err)
	}
}

func TestSpoofingAndJumps(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	me := e.user(t, matching.Hobby, false)
	if _, err := e.svc.UpdateLocation(ctx, me, baseLat, baseLon, true); !errors.Is(err, ErrSuspicious) {
		t.Fatalf("подмена GPS: %v", err)
	}
	if _, err := e.svc.Radar(ctx, me, matching.Hobby); !errors.Is(err, ErrSuspicious) {
		t.Fatalf("радар после подмены: %v", err)
	}

	other := e.user(t, matching.Hobby, false)
	e.at(t, other, [2]float64{baseLat, baseLon})
	*e.clock = e.clock.Add(time.Minute)
	if _, err := e.svc.UpdateLocation(ctx, other, far100k[0], far100k[1], false); !errors.Is(err, ErrSuspicious) {
		t.Fatalf("100 км за минуту: %v", err)
	}
	if _, err := e.svc.UpdateLocation(ctx, other, 91, 0, false); !errors.Is(err, ErrBadCoordinates) {
		t.Fatalf("координаты вне диапазона: %v", err)
	}
}

func TestNotifications(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	me := e.user(t, matching.Hobby, false)
	her := e.user(t, matching.Hobby, false)
	e.at(t, me, [2]float64{baseLat, baseLon})
	e.at(t, her, near300)

	if _, err := e.svc.CreateTemplate(ctx, me, Template{Goal: matching.Hobby, Name: "Хобби", Prefs: matching.Prefs{Height: matching.Range{Min: 170}}}); err == nil {
		t.Fatal("рост в шаблоне «Хобби» недопустим")
	}
	tpl, err := e.svc.CreateTemplate(ctx, me, Template{Goal: matching.Hobby, Name: "Напарник на мотопробег",
		NotifyNearby: true, MinScore: 10, QuietFrom: "23:00", QuietTo: "08:00"})
	if err != nil {
		t.Fatal(err)
	}
	if list, _ := e.svc.Templates(ctx, me); len(list) != 1 || list[0].QuietFrom != "23:00" || list[0].ID != tpl.ID {
		t.Fatalf("шаблоны: %+v", list)
	}

	n, err := e.svc.RunNotifications(ctx)
	if err != nil || n != 1 {
		t.Fatalf("первая рассылка: %d %v", n, err)
	}
	want := "До 500 м — человек с 2 общими интересами: "
	if !strings.HasPrefix(e.push.msgs[0], want) {
		t.Fatalf("текст уведомления: %q", e.push.msgs[0])
	}
	if n, _ := e.svc.RunNotifications(ctx); n != 0 {
		t.Fatal("об одном человеке — не чаще раза в 7 дней")
	}

	// Тихие часы: 23:30 по Чите.
	if _, err := e.db.Exec(ctx, `DELETE FROM nearby_notifications`); err != nil {
		t.Fatal(err)
	}
	*e.clock = time.Date(2026, 11, 12, 14, 30, 0, 0, time.UTC)
	e.at(t, me, [2]float64{baseLat, baseLon})
	e.at(t, her, near300)
	if n, _ := e.svc.RunNotifications(ctx); n != 0 {
		t.Fatal("в тихие часы уведомлений нет")
	}
}

func TestQuietAndText(t *testing.T) {
	at := func(h, m int) time.Time { return time.Date(2026, 1, 1, h, m, 0, 0, time.UTC) }
	if !inQuiet(at(23, 30), "23:00", "08:00") || !inQuiet(at(7, 59), "23:00", "08:00") || inQuiet(at(12, 0), "23:00", "08:00") {
		t.Error("тихие часы через полночь")
	}
	if !inQuiet(at(14, 0), "13:00", "15:00") || inQuiet(at(15, 0), "13:00", "15:00") || inQuiet(at(14, 0), "", "") {
		t.Error("тихие часы днём")
	}
	c := feed.Card{Distance: "до 1 км", Shared: []matching.SharedInterest{{Name: "Эндуро"}}}
	if got := NotificationText(c); got != "До 1 км — человек с 1 общим интересом: эндуро" {
		t.Errorf("текст: %q", got)
	}
}
