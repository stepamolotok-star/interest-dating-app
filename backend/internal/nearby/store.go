package nearby

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/geo"
)

// Ключи Redis. Здесь живёт только текущая геоячейка (≈150 м), и только
// LocationTTL. Точные координаты не сохраняются нигде.
const (
	keyGeo       = "nearby:geo"
	LocationTTL  = 10 * time.Minute
	BucketTTL    = 15 * time.Minute // интервал расстояния для пары не меняется 15 минут
	SuspicionTTL = time.Hour
)

func keyCell(id string) string { return "nearby:cell:" + id }
func keySusp(id string) string { return "nearby:susp:" + id }
func keyRate(id string) string { return "nearby:rl:" + id }

// store — работа с Redis.
type store struct{ r *redis.Client }

type position struct {
	Cell string
	At   time.Time
}

func (s store) put(ctx context.Context, userID, cell string, at time.Time) error {
	c, err := geo.Decode(cell)
	if err != nil {
		return err
	}
	lat, lon := c.Center()
	pipe := s.r.TxPipeline()
	pipe.GeoAdd(ctx, keyGeo, &redis.GeoLocation{Name: userID, Latitude: lat, Longitude: lon})
	pipe.Set(ctx, keyCell(userID), cell+"|"+strconv.FormatInt(at.Unix(), 10), LocationTTL)
	_, err = pipe.Exec(ctx)
	return err
}

func (s store) remove(ctx context.Context, userID string) error {
	pipe := s.r.TxPipeline()
	pipe.ZRem(ctx, keyGeo, userID)
	pipe.Del(ctx, keyCell(userID))
	_, err := pipe.Exec(ctx)
	return err
}

func (s store) get(ctx context.Context, userID string) (position, bool, error) {
	v, err := s.r.Get(ctx, keyCell(userID)).Result()
	if errors.Is(err, redis.Nil) {
		return position{}, false, nil
	}
	if err != nil {
		return position{}, false, err
	}
	return parsePosition(v)
}

func parsePosition(v string) (position, bool, error) {
	cell, ts, ok := strings.Cut(v, "|")
	if !ok {
		return position{}, false, fmt.Errorf("nearby: битая запись %q", v)
	}
	sec, err := strconv.ParseInt(ts, 10, 64)
	if err != nil {
		return position{}, false, err
	}
	return position{Cell: cell, At: time.Unix(sec, 0)}, true, nil
}

// within — люди со свежей позицией в радиусе от ячейки. Устаревшие записи
// попутно удаляются из гео-индекса.
func (s store) within(ctx context.Context, cell string, radiusM float64) (map[string]position, error) {
	c, err := geo.Decode(cell)
	if err != nil {
		return nil, err
	}
	lat, lon := c.Center()
	ids, err := s.r.GeoSearch(ctx, keyGeo, &redis.GeoSearchQuery{
		Longitude: lon, Latitude: lat, Radius: radiusM + c.HalfDiagonalM()*2, RadiusUnit: "m",
	}).Result()
	if err != nil || len(ids) == 0 {
		return map[string]position{}, err
	}
	keys := make([]string, len(ids))
	for i, id := range ids {
		keys[i] = keyCell(id)
	}
	vals, err := s.r.MGet(ctx, keys...).Result()
	if err != nil {
		return nil, err
	}
	out := make(map[string]position, len(ids))
	var stale []any
	for i, v := range vals {
		str, ok := v.(string)
		if !ok {
			stale = append(stale, ids[i])
			continue
		}
		if p, ok, err := parsePosition(str); err == nil && ok {
			out[ids[i]] = p
		}
	}
	if len(stale) > 0 {
		s.r.ZRem(ctx, keyGeo, stale...)
	}
	return out, nil
}

func (s store) suspicious(ctx context.Context, userID string) (bool, error) {
	n, err := s.r.Exists(ctx, keySusp(userID)).Result()
	return n > 0, err
}

func (s store) markSuspicious(ctx context.Context, userID string) error {
	if err := s.r.Set(ctx, keySusp(userID), 1, SuspicionTTL).Err(); err != nil {
		return err
	}
	return s.remove(ctx, userID)
}

// allow — не больше limit запросов в минуту.
func (s store) allow(ctx context.Context, userID string, limit int64) (bool, error) {
	pipe := s.r.TxPipeline()
	incr := pipe.Incr(ctx, keyRate(userID))
	pipe.ExpireNX(ctx, keyRate(userID), time.Minute)
	if _, err := pipe.Exec(ctx); err != nil {
		return false, err
	}
	return incr.Val() <= limit, nil
}

// stableBucket возвращает интервал для пары, зафиксированный на BucketTTL:
// частые запросы не позволят «сужать круг».
func (s store) stableBucket(ctx context.Context, a, b, goal string, compute func() (geo.Bucket, error)) (geo.Bucket, error) {
	if a > b {
		a, b = b, a
	}
	key := "nearby:bucket:" + goal + ":" + a + ":" + b
	if v, err := s.r.Get(ctx, key).Int(); err == nil {
		return geo.Bucket(v), nil
	} else if !errors.Is(err, redis.Nil) {
		return 0, err
	}
	bucket, err := compute()
	if err != nil {
		return 0, err
	}
	return bucket, s.r.Set(ctx, key, int(bucket), BucketTTL).Err()
}
