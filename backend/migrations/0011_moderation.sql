-- Модерация: блокировки, временное отстранение, предупреждения, решения по жалобам.

ALTER TABLE users
    ADD COLUMN banned_at       timestamptz,   -- навсегда: вход закрыт, номер в banned_phones
    ADD COLUMN ban_reason      text,
    ADD COLUMN suspended_until timestamptz,   -- временно: вход закрыт до этого времени
    ADD COLUMN on_hold         boolean NOT NULL DEFAULT false, -- скрыт из ленты и «Рядом» до решения модератора
    ADD COLUMN warning         text,          -- предупреждение модератора, ещё не прочитанное
    ADD COLUMN warned_at       timestamptz;

-- Заблокированные номера. Храним не сам номер, а ключ (HMAC, как phone_key):
-- номер нельзя прочитать, но повторная регистрация с ним не пройдёт.
CREATE TABLE banned_phones (
    phone_key  bytea PRIMARY KEY,
    reason     text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE reports
    ADD COLUMN moderator  text,
    ADD COLUMN resolution text;  -- dismiss / warn / suspend / ban

ALTER TABLE moderation_actions DROP CONSTRAINT moderation_actions_action_check;
ALTER TABLE moderation_actions ADD CONSTRAINT moderation_actions_action_check
    CHECK (action IN ('warn','hide_photo','restrict_nearby','suspend','ban','unban','dismiss','hold','release'));
ALTER TABLE moderation_actions
    ADD COLUMN note  text,
    ADD COLUMN until timestamptz;

CREATE INDEX reports_target_idx ON reports (target, created_at DESC);
CREATE INDEX messages_sender_recent_idx ON messages (sender, created_at DESC);
CREATE INDEX interests_expressed_from_recent_idx ON interests_expressed (from_user, created_at DESC);
