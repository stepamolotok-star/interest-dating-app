package photos

import (
	"bytes"
	"encoding/binary"
	"errors"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"testing"
)

// jpegWithOrientation собирает JPEG w×h с тегом EXIF Orientation и меткой GPS-подобного текста.
func jpegWithOrientation(t *testing.T, w, h, o int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, color.RGBA{200, 30, 30, 255})
		}
	}
	for y := 0; y < 10; y++ { // синий квадрат в левом верхнем углу
		for x := 0; x < 10; x++ {
			img.Set(x, y, color.RGBA{0, 0, 255, 255})
		}
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 95}); err != nil {
		t.Fatal(err)
	}
	raw := buf.Bytes()
	// TIFF: II, 42, смещение IFD 8, одна запись — Orientation (SHORT).
	tiff := []byte("II*\x00\x08\x00\x00\x00")
	ifd := make([]byte, 2+12+4)
	binary.LittleEndian.PutUint16(ifd[0:], 1)
	binary.LittleEndian.PutUint16(ifd[2:], 0x0112)
	binary.LittleEndian.PutUint16(ifd[4:], 3)
	binary.LittleEndian.PutUint32(ifd[6:], 1)
	binary.LittleEndian.PutUint16(ifd[10:], uint16(o))
	payload := append([]byte("Exif\x00\x00"), append(tiff, ifd...)...)
	payload = append(payload, []byte("GPS 52.03N 113.50E")...)
	seg := []byte{0xFF, 0xE1, 0, 0}
	binary.BigEndian.PutUint16(seg[2:], uint16(len(payload)+2))
	seg = append(seg, payload...)
	out := append([]byte{}, raw[:2]...)
	out = append(out, seg...)
	return append(out, raw[2:]...)
}

func TestPrepareRotatesAndStripsMetadata(t *testing.T) {
	src := jpegWithOrientation(t, 40, 20, 6)
	if orientation(src) != 6 {
		t.Fatalf("orientation = %d", orientation(src))
	}
	out, err := Prepare(src)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(out, []byte("Exif")) || bytes.Contains(out, []byte("GPS")) {
		t.Fatal("метаданные остались в файле")
	}
	cfg, err := jpeg.DecodeConfig(bytes.NewReader(out))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Width != 20 || cfg.Height != 40 {
		t.Fatalf("после поворота %d×%d, ждали 20×40", cfg.Width, cfg.Height)
	}
	// Поворот на 90° по часовой: левый верхний угол уходит в правый верхний.
	dec, _ := jpeg.Decode(bytes.NewReader(out))
	if r, _, b, _ := dec.At(15, 4).RGBA(); b>>8 < 180 || r>>8 > 80 {
		t.Fatalf("синий угол не на месте: r=%d b=%d", r>>8, b>>8)
	}
}

func TestPrepareResizesAndFlattens(t *testing.T) {
	img := image.NewNRGBA(image.Rect(0, 0, 3200, 1000)) // прозрачная
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	out, err := Prepare(buf.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	dec, err := jpeg.Decode(bytes.NewReader(out))
	if err != nil {
		t.Fatal(err)
	}
	if b := dec.Bounds(); b.Dx() != MaxSide || b.Dy() != 500 {
		t.Fatalf("размер %v", b)
	}
	if r, g, b, _ := dec.At(10, 10).RGBA(); r>>8 < 250 || g>>8 < 250 || b>>8 < 250 {
		t.Fatal("прозрачный фон должен стать белым")
	}
}

func TestPrepareRejects(t *testing.T) {
	if _, err := Prepare([]byte("<svg>не картинка</svg>")); !errors.Is(err, ErrBadImage) {
		t.Fatalf("мусор: %v", err)
	}
	if _, err := Prepare(make([]byte, MaxUploadBytes+1)); !errors.Is(err, ErrTooBig) {
		t.Fatalf("большой файл: %v", err)
	}
}

func TestDiskStoreKeys(t *testing.T) {
	d := DiskStore{Dir: t.TempDir()}
	if err := d.Put(t.Context(), "../evil.jpg", []byte("x")); err == nil {
		t.Fatal("ключ с .. должен отклоняться")
	}
	if err := d.Put(t.Context(), "u/p.jpg", []byte("ok")); err != nil {
		t.Fatal(err)
	}
	if b, err := d.Get(t.Context(), "u/p.jpg"); err != nil || string(b) != "ok" {
		t.Fatalf("%q %v", b, err)
	}
	if err := d.Delete(t.Context(), "u/p.jpg"); err != nil {
		t.Fatal(err)
	}
	if _, err := d.Get(t.Context(), "u/p.jpg"); !errors.Is(err, ErrNotFound) {
		t.Fatal(err)
	}
}
