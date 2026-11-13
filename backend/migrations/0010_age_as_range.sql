-- В карточке теперь точный возраст. Кто хочет скрыть его — включает «показывать диапазоном».
ALTER TABLE profiles ADD COLUMN age_as_range boolean NOT NULL DEFAULT false;
