-- Вход по номеру телефона: звонок-сброс (код — последние 4 цифры номера,
-- с которого звонят) или запасной SMS. Коды и токены храним только в виде
-- HMAC/хэша — утечка базы не даёт войти в чужой аккаунт.

CREATE TABLE auth_attempts (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    phone_e164  text NOT NULL,
    method      text NOT NULL CHECK (method IN ('flash_call', 'sms')),
    code_hash   bytea NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL,
    attempts    smallint NOT NULL DEFAULT 0,
    consumed_at timestamptz
);
CREATE INDEX auth_attempts_phone_idx ON auth_attempts (phone_e164, created_at DESC);

-- Сессия появляется сразу после проверки кода. Для нового человека user_id
-- пустой, пока он не заполнит регистрацию.
CREATE TABLE sessions (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    token_hash bytea NOT NULL UNIQUE,
    phone_e164 text NOT NULL,
    user_id    uuid REFERENCES users(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz
);
CREATE INDEX sessions_user_idx ON sessions (user_id);
