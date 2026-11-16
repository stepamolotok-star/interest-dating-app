-- Фото анкеты: файлы лежат в хранилище (пока — папка на сервере), здесь только порядок.
-- Размытые копии не делаем: до взаимности вместо фото показываем замок.

ALTER TABLE photos DROP CONSTRAINT IF EXISTS photos_user_id_position_key;
ALTER TABLE photos DROP CONSTRAINT IF EXISTS photos_position_check;
ALTER TABLE photos ALTER COLUMN blurred_key DROP NOT NULL;
ALTER TABLE photos ALTER COLUMN moderation SET DEFAULT 'approved';
ALTER TABLE photos ADD CONSTRAINT photos_position_check CHECK (position BETWEEN 0 AND 5);
CREATE INDEX photos_user_idx ON photos (user_id, position);

-- Журнал загрузок: предел в сутки считается и по удалённым фото.
CREATE TABLE photo_uploads (
    user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX photo_uploads_recent_idx ON photo_uploads (user_id, created_at DESC);
