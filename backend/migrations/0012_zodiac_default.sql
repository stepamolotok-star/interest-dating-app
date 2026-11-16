-- Знак зодиака виден по умолчанию; в «Приватности» его можно скрыть.
-- Пользователей ещё нет, поэтому включаем знак всем, а не только новым анкетам.

ALTER TABLE profiles ALTER COLUMN show_zodiac SET DEFAULT true;
UPDATE profiles SET show_zodiac = true;
