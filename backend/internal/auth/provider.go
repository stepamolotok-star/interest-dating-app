package auth

import (
	"context"
	"crypto/rand"
	"fmt"
	"log/slog"
	"math/big"
)

// Caller делает звонок-сброс и возвращает код — последние цифры номера,
// с которого позвонили. Реализацию даёт оператор (договор с поставщиком
// услуги flash call), здесь — только интерфейс.
type Caller interface {
	FlashCall(ctx context.Context, phone string) (code string, err error)
}

// SMSSender отправляет код по SMS — запасной способ, если звонок не дошёл.
type SMSSender interface {
	SendCode(ctx context.Context, phone, code string) error
}

// DevProvider — заглушка для разработки: никуда не звонит, а пишет код в лог.
// Никогда не включать в продакшене.
type DevProvider struct{ Log *slog.Logger }

func (p DevProvider) FlashCall(_ context.Context, phone string) (string, error) {
	code, err := RandomCode(CodeLength)
	if err != nil {
		return "", err
	}
	p.Log.Warn("DEV: звонок-сброс не выполнен, код в логе", "phone_tail", tail(phone), "code", code)
	return code, nil
}

func (p DevProvider) SendCode(_ context.Context, phone, code string) error {
	p.Log.Warn("DEV: SMS не отправлено, код в логе", "phone_tail", tail(phone), "code", code)
	return nil
}

// RandomCode — криптостойкий цифровой код заданной длины.
func RandomCode(n int) (string, error) {
	max := big.NewInt(1)
	for i := 0; i < n; i++ {
		max.Mul(max, big.NewInt(10))
	}
	v, err := rand.Int(rand.Reader, max)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%0*d", n, v), nil
}

// tail — последние цифры номера для логов: полный номер в лог не пишем.
func tail(phone string) string {
	if len(phone) <= 4 {
		return phone
	}
	return "…" + phone[len(phone)-4:]
}
