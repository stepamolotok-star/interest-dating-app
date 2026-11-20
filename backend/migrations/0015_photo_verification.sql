-- Проверка фото по селфи: человек повторяет случайный жест, модератор сравнивает
-- селфи с фото анкеты. Селфи хранится только до решения.

CREATE TABLE photo_verifications (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    gesture      text NOT NULL,
    status       text NOT NULL DEFAULT 'requested'
                 CHECK (status IN ('requested','pending','approved','rejected')),
    object_key   text NOT NULL DEFAULT '',
    note         text NOT NULL DEFAULT '',
    moderator    text NOT NULL DEFAULT '',
    created_at   timestamptz NOT NULL DEFAULT now(),
    submitted_at timestamptz,
    decided_at   timestamptz
);
CREATE INDEX photo_verifications_queue_idx ON photo_verifications (status, submitted_at);
CREATE INDEX photo_verifications_user_idx ON photo_verifications (user_id, created_at DESC);

ALTER TABLE moderation_actions DROP CONSTRAINT moderation_actions_action_check;
ALTER TABLE moderation_actions ADD CONSTRAINT moderation_actions_action_check
    CHECK (action IN ('warn','hide_photo','restrict_nearby','suspend','ban','unban','dismiss','hold','release',
                      'verify_photo','reject_photo'));
