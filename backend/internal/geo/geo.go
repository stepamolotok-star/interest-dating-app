// Package geo — геоячейки и интервалы расстояния для режима «Рядом».
//
// Главное правило: другим пользователям никогда не отдаются координаты или
// точное расстояние. Позиция сразу превращается в геоячейку (geohash,
// точность 7 ≈ 150 × 150 м), расстояние считается между центрами ячеек и
// округляется до интервала. Подробнее — docs/decisions.md.
package geo

import (
	"errors"
	"math"
	"strings"
)

// CellPrecision — длина geohash для позиции пользователя (~150 м).
const CellPrecision = 7

const base32 = "0123456789bcdefghjkmnpqrstuvwxyz"

// Encode кодирует координаты в geohash заданной точности.
func Encode(lat, lon float64, precision int) string {
	latLo, latHi := -90.0, 90.0
	lonLo, lonHi := -180.0, 180.0
	var sb strings.Builder
	bit, ch, even := 0, 0, true
	for sb.Len() < precision {
		if even {
			mid := (lonLo + lonHi) / 2
			if lon >= mid {
				ch = ch<<1 | 1
				lonLo = mid
			} else {
				ch <<= 1
				lonHi = mid
			}
		} else {
			mid := (latLo + latHi) / 2
			if lat >= mid {
				ch = ch<<1 | 1
				latLo = mid
			} else {
				ch <<= 1
				latHi = mid
			}
		}
		even = !even
		if bit++; bit == 5 {
			sb.WriteByte(base32[ch])
			bit, ch = 0, 0
		}
	}
	return sb.String()
}

// Cell — прямоугольник geohash.
type Cell struct {
	LatLo, LatHi, LonLo, LonHi float64
}

// Center — центр ячейки.
func (c Cell) Center() (lat, lon float64) {
	return (c.LatLo + c.LatHi) / 2, (c.LonLo + c.LonHi) / 2
}

// HalfDiagonalM — половина диагонали ячейки в метрах.
func (c Cell) HalfDiagonalM() float64 {
	return DistanceM(c.LatLo, c.LonLo, c.LatHi, c.LonHi) / 2
}

// ErrBadGeohash — строка не является geohash.
var ErrBadGeohash = errors.New("geo: некорректный geohash")

// Decode возвращает границы ячейки.
func Decode(hash string) (Cell, error) {
	if hash == "" {
		return Cell{}, ErrBadGeohash
	}
	c := Cell{-90, 90, -180, 180}
	even := true
	for _, r := range hash {
		idx := strings.IndexRune(base32, r)
		if idx < 0 {
			return Cell{}, ErrBadGeohash
		}
		for mask := 16; mask > 0; mask >>= 1 {
			if even {
				mid := (c.LonLo + c.LonHi) / 2
				if idx&mask != 0 {
					c.LonLo = mid
				} else {
					c.LonHi = mid
				}
			} else {
				mid := (c.LatLo + c.LatHi) / 2
				if idx&mask != 0 {
					c.LatLo = mid
				} else {
					c.LatHi = mid
				}
			}
			even = !even
		}
	}
	return c, nil
}

// DistanceM — расстояние по большой окружности в метрах.
func DistanceM(lat1, lon1, lat2, lon2 float64) float64 {
	const r = 6371000.0
	rad := math.Pi / 180
	dLat := (lat2 - lat1) * rad
	dLon := (lon2 - lon1) * rad
	a := math.Sin(dLat/2)*math.Sin(dLat/2) +
		math.Cos(lat1*rad)*math.Cos(lat2*rad)*math.Sin(dLon/2)*math.Sin(dLon/2)
	return 2 * r * math.Asin(math.Min(1, math.Sqrt(a)))
}

// Bucket — интервал расстояния, который видит пользователь.
type Bucket int

const (
	Under500m Bucket = iota
	Under1km
	From1to3km
	From3to10km
	Beyond10km
)

// Label — подпись для интерфейса.
func (b Bucket) Label() string {
	switch b {
	case Under500m:
		return "до 500 м"
	case Under1km:
		return "до 1 км"
	case From1to3km:
		return "1–3 км"
	case From3to10km:
		return "3–10 км"
	default:
		return "дальше 10 км"
	}
}

// BucketFor переводит расстояние в интервал.
func BucketFor(distanceM float64) Bucket {
	switch {
	case distanceM < 500:
		return Under500m
	case distanceM < 1000:
		return Under1km
	case distanceM < 3000:
		return From1to3km
	case distanceM < 10000:
		return From3to10km
	default:
		return Beyond10km
	}
}

// BucketBetween считает интервал между двумя ячейками. minBucket — нижняя
// граница точности: для цели «Без обязательств» это Under1km (ТЗ, раздел 8).
func BucketBetween(cellA, cellB string, minBucket Bucket) (Bucket, error) {
	a, err := Decode(cellA)
	if err != nil {
		return 0, err
	}
	b, err := Decode(cellB)
	if err != nil {
		return 0, err
	}
	alat, alon := a.Center()
	blat, blon := b.Center()
	bucket := BucketFor(DistanceM(alat, alon, blat, blon))
	if bucket < minBucket {
		bucket = minBucket
	}
	return bucket, nil
}

// Zone — личная зона (дом, работа), где пользователь невидим.
type Zone struct {
	Geohash string
	RadiusM float64
}

// InPrivateZone сообщает, может ли ячейка хотя бы частично попасть в одну
// из зон. Проверка нарочно осторожная: при сомнении пользователь невидим.
func InPrivateZone(cell string, zones []Zone) (bool, error) {
	c, err := Decode(cell)
	if err != nil {
		return false, err
	}
	lat, lon := c.Center()
	margin := c.HalfDiagonalM()
	for _, z := range zones {
		zc, err := Decode(z.Geohash)
		if err != nil {
			return false, err
		}
		zlat, zlon := zc.Center()
		if DistanceM(lat, lon, zlat, zlon) <= z.RadiusM+margin+zc.HalfDiagonalM() {
			return true, nil
		}
	}
	return false, nil
}
