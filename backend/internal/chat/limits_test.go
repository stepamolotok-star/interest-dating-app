package chat

import (
	"context"
	"errors"
	"fmt"
	"testing"

	"github.com/stepamolotok-star/interest-dating-app/backend/internal/limits"
)

// Рассылка одного текста многим, слишком частые сообщения и поток жалоб упираются в лимиты.
func TestSpamLimits(t *testing.T) {
	e := setup(t)
	ctx := context.Background()

	spammer := e.user(t, "Спамер")
	hello := "Привет!   Заходи на мой канал"
	for i := range limits.SameHelloPerDay + 1 {
		m := e.match(t, spammer, e.user(t, fmt.Sprintf("Жертва %d", i)))
		// Регистр и лишние пробелы не помогают обойти проверку.
		text := hello
		if i%2 == 1 {
			text = "привет! заходи на мой канал"
		}
		_, err := e.chat.Send(ctx, spammer, m, text)
		if i < limits.SameHelloPerDay && err != nil {
			t.Fatalf("сообщение %d: %v", i, err)
		}
		if i == limits.SameHelloPerDay && !errors.Is(err, limits.ErrSameHello) {
			t.Fatalf("%d-е одинаковое приветствие: %v", i+1, err)
		}
	}
	// Своё, другое приветствие проходит.
	m := e.match(t, spammer, e.user(t, "Ещё одна"))
	if _, err := e.chat.Send(ctx, spammer, m, "Привет! Вижу, ты тоже ходишь в походы — куда последний раз?"); err != nil {
		t.Fatalf("своё приветствие: %v", err)
	}

	// Скорость: больше MessagesPerMinute за минуту — нельзя.
	fast, friend := e.user(t, "Быстрый"), e.user(t, "Друг")
	fm := e.match(t, fast, friend)
	for i := range limits.MessagesPerMinute {
		if _, err := e.chat.Send(ctx, fast, fm, fmt.Sprintf("сообщение %d", i)); err != nil {
			t.Fatalf("сообщение %d: %v", i, err)
		}
	}
	if _, err := e.chat.Send(ctx, fast, fm, "ещё"); !errors.Is(err, limits.ErrTooFast) {
		t.Fatalf("слишком быстро: %v", err)
	}

	// Жалобы: не больше ReportsPerDay в сутки.
	angry := e.user(t, "Жалобщик")
	for i := range limits.ReportsPerDay + 1 {
		_, err := e.chat.Report(ctx, angry, e.user(t, fmt.Sprintf("Цель %d", i)), "spam", "")
		if i < limits.ReportsPerDay && err != nil {
			t.Fatalf("жалоба %d: %v", i, err)
		}
		if i == limits.ReportsPerDay && !errors.Is(err, limits.ErrReports) {
			t.Fatalf("лишняя жалоба: %v", err)
		}
	}
}
