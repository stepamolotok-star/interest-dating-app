package auth

import (
	"errors"
	"strings"
)

// ErrNotRussianMobile — номер не похож на российский мобильный.
// По 406-ФЗ регистрация возможна только по российскому номеру.
var ErrNotRussianMobile = errors.New("нужен российский мобильный номер: +7 9XX XXX-XX-XX")

// NormalizePhone приводит ввод пользователя к виду +79XXXXXXXXX.
// Принимает «+7 914 123-45-67», «89141234567», «9141234567».
func NormalizePhone(input string) (string, error) {
	var b strings.Builder
	for _, r := range input {
		if r >= '0' && r <= '9' {
			b.WriteRune(r)
		}
	}
	d := b.String()
	switch {
	case len(d) == 11 && (d[0] == '7' || d[0] == '8'):
		d = d[1:]
	case len(d) == 10:
	default:
		return "", ErrNotRussianMobile
	}
	if d[0] != '9' {
		return "", ErrNotRussianMobile
	}
	return "+7" + d, nil
}
