-- Push-уведомления: токены устройств и что человек хочет получать.

CREATE TABLE push_tokens (
    token      text PRIMARY KEY,                 -- токен один на устройство; при смене аккаунта переезжает
    user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider   text NOT NULL CHECK (provider IN ('rustore')),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX push_tokens_user_idx ON push_tokens (user_id);

-- Нет строки — всё включено, имя и текст на экране блокировки не показываем.
CREATE TABLE notification_settings (
    user_id   uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    matches   boolean NOT NULL DEFAULT true,
    messages  boolean NOT NULL DEFAULT true,
    nearby    boolean NOT NULL DEFAULT true,
    show_text boolean NOT NULL DEFAULT false
);
