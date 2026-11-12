package geo

import (
	"math"
	"testing"
)

func TestEncodeKnownValue(t *testing.T) {
	// Классический пример из описания geohash.
	if got := Encode(57.64911, 10.40744, 11); got != "u4pruydqqvj" {
		t.Fatalf("Encode = %s", got)
	}
}

func TestDecodeContainsPoint(t *testing.T) {
	lat, lon := 52.0337, 113.4994 // Чита
	h := Encode(lat, lon, CellPrecision)
	c, err := Decode(h)
	if err != nil {
		t.Fatal(err)
	}
	if lat < c.LatLo || lat > c.LatHi || lon < c.LonLo || lon > c.LonHi {
		t.Fatalf("точка вне своей ячейки: %+v", c)
	}
	if d := c.HalfDiagonalM(); d < 50 || d > 150 {
		t.Fatalf("половина диагонали ячейки точности 7 должна быть ~100 м, получили %.0f", d)
	}
	if _, err := Decode("ab!"); err == nil {
		t.Fatal("ожидали ошибку для некорректного geohash")
	}
}

func TestDistance(t *testing.T) {
	// Один градус широты ≈ 111.2 км.
	if d := DistanceM(0, 0, 1, 0); math.Abs(d-111195) > 100 {
		t.Fatalf("DistanceM = %.0f", d)
	}
}

func TestBuckets(t *testing.T) {
	base := Encode(52.0337, 113.4994, CellPrecision)
	near := Encode(52.0350, 113.5010, CellPrecision) // ~180 м
	far := Encode(52.0337, 113.5400, CellPrecision)  // ~2.8 км

	b, err := BucketBetween(base, near, Under500m)
	if err != nil || b != Under500m {
		t.Fatalf("рядом: %v %v", b, err)
	}
	if b, _ := BucketBetween(base, near, Under1km); b != Under1km {
		t.Fatalf("для «Без обязательств» точность не выше «до 1 км», получили %s", b.Label())
	}
	if b, _ := BucketBetween(base, far, Under500m); b != From1to3km {
		t.Fatalf("далеко: %s", b.Label())
	}
	if Beyond10km.Label() != "дальше 10 км" || BucketFor(9999) != From3to10km {
		t.Fatal("границы интервалов")
	}
}

func TestPrivateZone(t *testing.T) {
	home := Zone{Geohash: Encode(52.0337, 113.4994, CellPrecision), RadiusM: 500}
	inside := Encode(52.0360, 113.5020, CellPrecision)  // ~300 м от дома
	outside := Encode(52.0500, 113.5300, CellPrecision) // ~2.7 км

	if in, _ := InPrivateZone(inside, []Zone{home}); !in {
		t.Fatal("ячейка рядом с домом должна быть в зоне")
	}
	if in, _ := InPrivateZone(outside, []Zone{home}); in {
		t.Fatal("далёкая ячейка не должна быть в зоне")
	}
	if in, _ := InPrivateZone(outside, nil); in {
		t.Fatal("без зон пользователь видим")
	}
}
