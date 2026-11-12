// Package nearby — режим «Рядом» (ТЗ, раздел 6).
//
// Правила, которые здесь соблюдаются:
//   - видеть других может только тот, кто сам видим (симметрия);
//   - наружу уходит только интервал расстояния, посчитанный между центрами
//     геоячеек, и он не меняется 15 минут для пары;
//   - в личных зонах (дом, работа) человек невидим;
//   - история перемещений не хранится: только текущая ячейка на 10 минут;
//   - подмена GPS и невозможные скачки отключают «Рядом» на час.
package nearby

import (
	"context"
	"errors"
	"log/slog"
	"math"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/feed"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/geo"
	"github.com/stepamolotok-star/interest-dating-app/backend/internal/matching"
)

// Режимы видимости.
const (
	ModeOff        = "off"
	ModeForeground = "foreground" // только пока приложение открыто
	ModeBackground = "background"
	ModeTimed      = "timed" // на N часов, потом выключается сама
)

// Ограничения.
const (
	RadarPerMinute = 6
	MaxSpeedMS     = 300 / 3.6 // быстрее 300 км/ч — подозрительный скачок
	MinJumpM       = 2000      // мелкие скачки GPS не считаем
	MinZoneRadiusM = 500
	MaxZones       = 10
)

// Ошибки.
var (
	ErrNotVisible     = errors.New("чтобы видеть людей рядом, включите свою видимость: видеть других может только тот, кто виден сам")
	ErrNoLocation     = errors.New("нет свежей геопозиции — откройте приложение с включённой геолокацией")
	ErrTooFrequent    = errors.New("слишком часто — обновите через минуту")
	ErrSuspicious     = errors.New("похоже на подмену геопозиции — режим «Рядом» недоступен в течение часа")
	ErrBadCoordinates = errors.New("некорректные координаты")
)

// ValidationError — ошибка входных данных.
type ValidationError struct{ Field, Message string }

func (e *ValidationError) Error() string { return e.Field + ": " + e.Message }

// Pusher отправляет push-уведомление. Реализация — FCM, APNs, RuStore.
type Pusher interface {
	Push(ctx context.Context, userID, title, body string) error
}

// LogPusher — заглушка для разработки.
type LogPusher struct{ Log *slog.Logger }

func (p LogPusher) Push(_ context.Context, userID, title, body string) error {
	p.Log.Info("DEV: push", "user", userID, "title", title, "body", body)
	return nil
}

// Service — режим «Рядом».
type Service struct {
	DB    *pgxpool.Pool
	Redis *redis.Client
	Feed  *feed.Service
	Push  Pusher
	Now   func() time.Time
}

func (s *Service) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

func (s *Service) st() store { return store{s.Redis} }

// Visibility — настройки видимости.
type Visibility struct {
	Mode             string     `json:"mode"`
	VisibleUntil     *time.Time `json:"visible_until,omitempty"`
	RadiusM          int        `json:"radius_m"`
	VerifiedOnly     bool       `json:"verified_only"`
	HideFromContacts bool       `json:"hide_from_contacts"`
	Active           bool       `json:"active"`
}

func active(mode string, until *time.Time, now time.Time) bool {
	switch mode {
	case ModeForeground, ModeBackground:
		return true
	case ModeTimed:
		return until != nil && until.After(now)
	default:
		return false
	}
}

// GetVisibility возвращает настройки.
func (s *Service) GetVisibility(ctx context.Context, userID string) (Visibility, error) {
	var v Visibility
	err := s.DB.QueryRow(ctx, `SELECT mode, visible_until, radius_m, verified_only, hide_from_contacts
		FROM visibility_settings WHERE user_id = $1`, userID).Scan(&v.Mode, &v.VisibleUntil, &v.RadiusM, &v.VerifiedOnly, &v.HideFromContacts)
	if errors.Is(err, pgx.ErrNoRows) {
		return Visibility{Mode: ModeOff, RadiusM: 1000}, nil
	}
	if err != nil {
		return Visibility{}, err
	}
	v.Active = active(v.Mode, v.VisibleUntil, s.now())
	return v, nil
}

// SetVisibilityInput — что можно поменять.
type SetVisibilityInput struct {
	Mode             string `json:"mode"`
	Hours            int    `json:"hours"` // для ModeTimed: от 1 до 12
	RadiusM          int    `json:"radius_m"`
	VerifiedOnly     bool   `json:"verified_only"`
	HideFromContacts bool   `json:"hide_from_contacts"`
}

// SetVisibility меняет видимость. Выключение сразу убирает человека из «Рядом».
func (s *Service) SetVisibility(ctx context.Context, userID string, in SetVisibilityInput) (Visibility, error) {
	var until *time.Time
	switch in.Mode {
	case ModeOff, ModeForeground, ModeBackground:
	case ModeTimed:
		if in.Hours < 1 || in.Hours > 12 {
			return Visibility{}, &ValidationError{"hours", "от 1 до 12 часов"}
		}
		t := s.now().Add(time.Duration(in.Hours) * time.Hour)
		until = &t
	default:
		return Visibility{}, &ValidationError{"mode", "неизвестный режим"}
	}
	if in.RadiusM == 0 {
		in.RadiusM = 1000
	}
	if in.RadiusM != 300 && in.RadiusM != 1000 && in.RadiusM != 3000 && in.RadiusM != 10000 {
		return Visibility{}, &ValidationError{"radius_m", "радиус: 300, 1000, 3000 или 10000 м"}
	}
	_, err := s.DB.Exec(ctx, `INSERT INTO visibility_settings (user_id, mode, visible_until, radius_m, verified_only, hide_from_contacts)
		VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (user_id) DO UPDATE SET mode = $2, visible_until = $3, radius_m = $4, verified_only = $5, hide_from_contacts = $6`,
		userID, in.Mode, until, in.RadiusM, in.VerifiedOnly, in.HideFromContacts)
	if err != nil {
		return Visibility{}, err
	}
	if in.Mode == ModeOff {
		if err := s.st().remove(ctx, userID); err != nil {
			return Visibility{}, err
		}
	}
	return s.GetVisibility(ctx, userID)
}

// Disappear — кнопка «Исчезнуть»: видимость выключается везде мгновенно.
func (s *Service) Disappear(ctx context.Context, userID string) error {
	if _, err := s.DB.Exec(ctx, `INSERT INTO visibility_settings (user_id, mode) VALUES ($1, 'off')
		ON CONFLICT (user_id) DO UPDATE SET mode = 'off', visible_until = NULL`, userID); err != nil {
		return err
	}
	return s.st().remove(ctx, userID)
}

// Zone — личная зона. Наружу отдаём центр ячейки, а не то, что прислал клиент.
type Zone struct {
	ID      string  `json:"id"`
	Name    string  `json:"name"`
	Lat     float64 `json:"lat"`
	Lon     float64 `json:"lon"`
	RadiusM int     `json:"radius_m"`
}

// AddZone добавляет личную зону.
func (s *Service) AddZone(ctx context.Context, userID, name string, lat, lon float64, radiusM int) (Zone, error) {
	if !validCoords(lat, lon) {
		return Zone{}, ErrBadCoordinates
	}
	if name == "" || len([]rune(name)) > 30 {
		return Zone{}, &ValidationError{"name", "название от 1 до 30 символов"}
	}
	if radiusM < MinZoneRadiusM || radiusM > 5000 {
		return Zone{}, &ValidationError{"radius_m", "радиус зоны от 500 до 5000 м"}
	}
	var n int
	if err := s.DB.QueryRow(ctx, `SELECT count(*) FROM private_zones WHERE user_id = $1`, userID).Scan(&n); err != nil {
		return Zone{}, err
	}
	if n >= MaxZones {
		return Zone{}, &ValidationError{"zones", "не больше 10 личных зон"}
	}
	cell := geo.Encode(lat, lon, geo.CellPrecision)
	z := Zone{Name: name, RadiusM: radiusM}
	if err := s.DB.QueryRow(ctx, `INSERT INTO private_zones (user_id, name, geohash, radius_m) VALUES ($1, $2, $3, $4) RETURNING id`,
		userID, name, cell, radiusM).Scan(&z.ID); err != nil {
		return Zone{}, err
	}
	c, _ := geo.Decode(cell)
	z.Lat, z.Lon = c.Center()
	// Если человек сейчас внутри новой зоны — он должен исчезнуть сразу.
	if pos, ok, err := s.st().get(ctx, userID); err == nil && ok {
		if in, _ := geo.InPrivateZone(pos.Cell, []geo.Zone{{Geohash: cell, RadiusM: float64(radiusM)}}); in {
			_ = s.st().remove(ctx, userID)
		}
	}
	return z, nil
}

// Zones — личные зоны пользователя.
func (s *Service) Zones(ctx context.Context, userID string) ([]Zone, error) {
	rows, err := s.DB.Query(ctx, `SELECT id, name, geohash, radius_m FROM private_zones WHERE user_id = $1 ORDER BY name`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Zone{}
	for rows.Next() {
		var z Zone
		var cell string
		if err := rows.Scan(&z.ID, &z.Name, &cell, &z.RadiusM); err != nil {
			return nil, err
		}
		if c, err := geo.Decode(cell); err == nil {
			z.Lat, z.Lon = c.Center()
		}
		out = append(out, z)
	}
	return out, rows.Err()
}

// DeleteZone удаляет зону.
func (s *Service) DeleteZone(ctx context.Context, userID, zoneID string) error {
	_, err := s.DB.Exec(ctx, `DELETE FROM private_zones WHERE user_id = $1 AND id::text = $2`, userID, zoneID)
	return err
}

func (s *Service) zones(ctx context.Context, userID string) ([]geo.Zone, error) {
	rows, err := s.DB.Query(ctx, `SELECT geohash, radius_m FROM private_zones WHERE user_id = $1`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []geo.Zone
	for rows.Next() {
		var z geo.Zone
		var r int
		if err := rows.Scan(&z.Geohash, &r); err != nil {
			return nil, err
		}
		z.RadiusM = float64(r)
		out = append(out, z)
	}
	return out, rows.Err()
}

// LocationStatus — виден ли человек после обновления позиции.
type LocationStatus struct {
	Visible bool   `json:"visible"`
	Reason  string `json:"reason,omitempty"` // visibility_off | private_zone
}

// UpdateLocation принимает позицию от приложения. Координаты сразу
// превращаются в ячейку и дальше нигде не хранятся.
func (s *Service) UpdateLocation(ctx context.Context, userID string, lat, lon float64, mocked bool) (LocationStatus, error) {
	if !validCoords(lat, lon) {
		return LocationStatus{}, ErrBadCoordinates
	}
	st := s.st()
	now := s.now()
	if mocked {
		return LocationStatus{}, errors.Join(ErrSuspicious, st.markSuspicious(ctx, userID))
	}
	if susp, err := st.suspicious(ctx, userID); err != nil || susp {
		return LocationStatus{}, errors.Join(ErrSuspicious, err)
	}
	cell := geo.Encode(lat, lon, geo.CellPrecision)

	vis, err := s.GetVisibility(ctx, userID)
	if err != nil {
		return LocationStatus{}, err
	}
	if !vis.Active {
		return LocationStatus{Reason: "visibility_off"}, st.remove(ctx, userID)
	}
	zones, err := s.zones(ctx, userID)
	if err != nil {
		return LocationStatus{}, err
	}
	if in, err := geo.InPrivateZone(cell, zones); err != nil {
		return LocationStatus{}, err
	} else if in {
		return LocationStatus{Reason: "private_zone"}, st.remove(ctx, userID)
	}
	if prev, ok, err := st.get(ctx, userID); err != nil {
		return LocationStatus{}, err
	} else if ok {
		if d := cellDistance(prev.Cell, cell); d > MinJumpM {
			if dt := now.Sub(prev.At).Seconds(); dt <= 0 || d/dt > MaxSpeedMS {
				return LocationStatus{}, errors.Join(ErrSuspicious, st.markSuspicious(ctx, userID))
			}
		}
	}
	if err := st.put(ctx, userID, cell, now); err != nil {
		return LocationStatus{}, err
	}
	return LocationStatus{Visible: true}, nil
}

// Radar — люди рядом, подходящие по цели и фильтрам в обе стороны.
func (s *Service) Radar(ctx context.Context, viewerID string, goal matching.Goal) ([]feed.Card, error) {
	st := s.st()
	if susp, err := st.suspicious(ctx, viewerID); err != nil {
		return nil, err
	} else if susp {
		return nil, ErrSuspicious
	}
	if ok, err := st.allow(ctx, viewerID, RadarPerMinute); err != nil {
		return nil, err
	} else if !ok {
		return nil, ErrTooFrequent
	}
	return s.nearbyCards(ctx, viewerID, goal, nil)
}

// nearbyCards — общая часть радара и уведомлений.
func (s *Service) nearbyCards(ctx context.Context, viewerID string, goal matching.Goal, prefs *matching.Prefs) ([]feed.Card, error) {
	st := s.st()
	now := s.now()
	me, err := s.settings(ctx, []string{viewerID}, goal)
	if err != nil {
		return nil, err
	}
	v, ok := me[viewerID]
	if !ok || !v.visibleFor(now) {
		return nil, ErrNotVisible
	}
	pos, ok, err := st.get(ctx, viewerID)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, ErrNoLocation
	}
	around, err := st.within(ctx, pos.Cell, float64(v.radius))
	if err != nil {
		return nil, err
	}
	delete(around, viewerID)
	if len(around) == 0 {
		return []feed.Card{}, nil
	}
	ids := make([]string, 0, len(around))
	for id := range around {
		ids = append(ids, id)
	}
	others, err := s.settings(ctx, ids, goal)
	if err != nil {
		return nil, err
	}
	var ok2 []string
	for id, o := range others {
		if !o.visibleFor(now) || (o.verifiedOnly && !v.photoVerified) {
			continue
		}
		// Радиус — меньший из двух: никто не виден дальше, чем сам разрешил.
		limit := math.Min(float64(v.radius), float64(o.radius))
		if cellDistance(pos.Cell, around[id].Cell) > limit {
			continue
		}
		ok2 = append(ok2, id)
	}
	cards, err := s.Feed.Rank(ctx, viewerID, goal, ok2, prefs)
	if err != nil {
		return nil, err
	}
	minBucket := geo.Under500m
	if goal == matching.Casual {
		minBucket = geo.Under1km
	}
	buckets := map[string]geo.Bucket{}
	for i := range cards {
		other := around[cards[i].UserID]
		b, err := st.stableBucket(ctx, viewerID, cards[i].UserID, string(goal), func() (geo.Bucket, error) {
			return geo.BucketBetween(pos.Cell, other.Cell, minBucket)
		})
		if err != nil {
			return nil, err
		}
		buckets[cards[i].UserID] = b
		cards[i].Distance = b.Label()
	}
	sort.SliceStable(cards, func(i, j int) bool {
		bi, bj := buckets[cards[i].UserID], buckets[cards[j].UserID]
		if bi != bj {
			return bi < bj
		}
		return cards[i].Score > cards[j].Score
	})
	return cards, nil
}

type nearbySettings struct {
	mode          string
	until         *time.Time
	radius        int
	verifiedOnly  bool
	goalVisible   bool
	photoVerified bool
}

func (n nearbySettings) visibleFor(now time.Time) bool {
	return n.goalVisible && active(n.mode, n.until, now)
}

func (s *Service) settings(ctx context.Context, ids []string, goal matching.Goal) (map[string]nearbySettings, error) {
	rows, err := s.DB.Query(ctx, `
		SELECT u.id, coalesce(vs.mode, 'off'), vs.visible_until, coalesce(vs.radius_m, 1000), coalesce(vs.verified_only, false),
		       coalesce(g.active AND g.nearby_visible, false), u.photo_verified_at IS NOT NULL
		FROM users u
		LEFT JOIN visibility_settings vs ON vs.user_id = u.id
		LEFT JOIN user_goals g ON g.user_id = u.id AND g.goal = $2
		WHERE u.id = ANY($1::uuid[]) AND u.deleted_at IS NULL`, ids, goal)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make(map[string]nearbySettings, len(ids))
	for rows.Next() {
		var id string
		var n nearbySettings
		if err := rows.Scan(&id, &n.mode, &n.until, &n.radius, &n.verifiedOnly, &n.goalVisible, &n.photoVerified); err != nil {
			return nil, err
		}
		out[id] = n
	}
	return out, rows.Err()
}

func cellDistance(a, b string) float64 {
	ca, err1 := geo.Decode(a)
	cb, err2 := geo.Decode(b)
	if err1 != nil || err2 != nil {
		return math.Inf(1)
	}
	alat, alon := ca.Center()
	blat, blon := cb.Center()
	return geo.DistanceM(alat, alon, blat, blon)
}

func validCoords(lat, lon float64) bool {
	return lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180 && !(lat == 0 && lon == 0)
}
