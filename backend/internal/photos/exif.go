package photos

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/draw"
)

// orientation читает из JPEG тег EXIF Orientation (1–8). Телефоны часто не
// поворачивают пиксели, а только ставят тег; сами теги мы выбрасываем (там бывает
// GPS), поэтому поворот надо применить заранее. 1 — «как есть» и любые ошибки.
func orientation(data []byte) int {
	if len(data) < 4 || data[0] != 0xFF || data[1] != 0xD8 {
		return 1
	}
	i := 2
	for i+4 <= len(data) {
		if data[i] != 0xFF {
			return 1
		}
		marker := data[i+1]
		if marker == 0xDA || marker == 0xD9 { // начались данные изображения
			return 1
		}
		size := int(binary.BigEndian.Uint16(data[i+2 : i+4]))
		if size < 2 || i+2+size > len(data) {
			return 1
		}
		seg := data[i+4 : i+2+size]
		if marker == 0xE1 && bytes.HasPrefix(seg, []byte("Exif\x00\x00")) {
			return tiffOrientation(seg[6:])
		}
		i += 2 + size
	}
	return 1
}

func tiffOrientation(t []byte) int {
	if len(t) < 8 {
		return 1
	}
	var bo binary.ByteOrder
	switch string(t[:2]) {
	case "II":
		bo = binary.LittleEndian
	case "MM":
		bo = binary.BigEndian
	default:
		return 1
	}
	ifd := int(bo.Uint32(t[4:8]))
	if ifd+2 > len(t) {
		return 1
	}
	n := int(bo.Uint16(t[ifd : ifd+2]))
	for k := 0; k < n; k++ {
		e := ifd + 2 + 12*k
		if e+12 > len(t) {
			return 1
		}
		if bo.Uint16(t[e:e+2]) == 0x0112 {
			v := int(bo.Uint16(t[e+8 : e+10]))
			if v >= 1 && v <= 8 {
				return v
			}
			return 1
		}
	}
	return 1
}

// orient поворачивает и отражает картинку по тегу EXIF Orientation.
func orient(src image.Image, o int) image.Image {
	if o <= 1 || o > 8 {
		return src
	}
	b := src.Bounds()
	w, h := b.Dx(), b.Dy()
	in := image.NewRGBA(image.Rect(0, 0, w, h))
	draw.Draw(in, in.Bounds(), src, b.Min, draw.Src)
	ow, oh := w, h
	if o >= 5 { // 5–8: стороны меняются местами
		ow, oh = h, w
	}
	out := image.NewRGBA(image.Rect(0, 0, ow, oh))
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			var nx, ny int
			switch o {
			case 2: // отражение по горизонтали
				nx, ny = w-1-x, y
			case 3: // 180°
				nx, ny = w-1-x, h-1-y
			case 4: // отражение по вертикали
				nx, ny = x, h-1-y
			case 5: // транспонирование
				nx, ny = y, x
			case 6: // 90° по часовой
				nx, ny = h-1-y, x
			case 7: // поперечное отражение
				nx, ny = h-1-y, w-1-x
			case 8: // 90° против часовой
				nx, ny = y, w-1-x
			}
			off := in.PixOffset(x, y)
			copy(out.Pix[out.PixOffset(nx, ny):out.PixOffset(nx, ny)+4], in.Pix[off:off+4])
		}
	}
	return out
}
