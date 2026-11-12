-- Начальная схема базы данных.
-- Принципы: точные координаты не хранятся (только в Redis с коротким сроком
-- жизни); у каждого поля профиля своя видимость; согласия на обработку
-- персональных данных фиксируются отдельными записями (152-ФЗ, ст. 9).

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Пользователи и вход ---------------------------------------------------------

CREATE TABLE users (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    phone_e164            text NOT NULL UNIQUE,          -- только российские номера (406-ФЗ)
    birth_date            date NOT NULL,
    gender                text NOT NULL CHECK (gender IN ('male', 'female')),
    photo_verified_at     timestamptz,                    -- проверка селфи
    gosuslugi_verified_at timestamptz,                    -- подтверждение 18+ через ЕСИА
    created_at            timestamptz NOT NULL DEFAULT now(),
    last_active_at        timestamptz NOT NULL DEFAULT now(),
    deleted_at            timestamptz,
    CHECK (birth_date <= (now() - interval '18 years')::date)
);

-- Согласия: каждое — отдельный документ со своей версией текста.
CREATE TABLE consents (
    id          bigserial PRIMARY KEY,
    user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind        text NOT NULL CHECK (kind IN (
                    'personal_data',      -- обработка ПДн
                    'special_category',   -- религия, взгляды (ст. 10 152-ФЗ)
                    'geolocation',        -- режим «Рядом»
                    'terms'               -- пользовательское соглашение
                )),
    doc_version text NOT NULL,
    granted_at  timestamptz NOT NULL DEFAULT now(),
    revoked_at  timestamptz
);
CREATE INDEX consents_user_idx ON consents (user_id, kind);

-- Профиль ---------------------------------------------------------------------

CREATE TABLE profiles (
    user_id        uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    display_name   text NOT NULL,
    city           text NOT NULL,
    about          text CHECK (char_length(about) <= 500),
    prompts        jsonb NOT NULL DEFAULT '[]',          -- [{question, answer}]
    height_cm      smallint CHECK (height_cm BETWEEN 120 AND 230),
    weight_kg      smallint CHECK (weight_kg BETWEEN 35 AND 250),
    body_type      text,
    habits         jsonb NOT NULL DEFAULT '{}',          -- {"smoking":"no","chronotype":"lark",...}
    diet           text CHECK (diet IN ('any','vegetarian','vegan','pescatarian','halal','kosher','healthy','keto','raw','fasting')),
    religion       text,                                  -- только при согласии special_category
    religion_for_matching boolean NOT NULL DEFAULT false,
    show_zodiac    boolean NOT NULL DEFAULT false,        -- знак вычисляется из даты рождения
    languages      jsonb NOT NULL DEFAULT '[]',
    updated_at     timestamptz NOT NULL DEFAULT now()
);

-- Видимость каждого поля профиля.
CREATE TABLE profile_field_visibility (
    user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    field      text NOT NULL,
    visibility text NOT NULL CHECK (visibility IN ('anonymous','after_match','matching_only','hidden')),
    PRIMARY KEY (user_id, field)
);

CREATE TABLE photos (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    object_key  text NOT NULL,       -- оригинал в объектном хранилище
    blurred_key text NOT NULL,       -- размытая версия для уровня 0
    position    smallint NOT NULL CHECK (position BETWEEN 0 AND 8),
    moderation  text NOT NULL DEFAULT 'pending' CHECK (moderation IN ('pending','approved','rejected')),
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, position)
);

-- Каталог интересов -----------------------------------------------------------

CREATE TABLE interests (
    id          text PRIMARY KEY,                -- стабильный слаг: "transport.moto.enduro"
    parent_id   text REFERENCES interests(id),
    depth       smallint NOT NULL CHECK (depth BETWEEN 0 AND 2),  -- 0 категория, 1 подкатегория, 2 увлечение
    name        text NOT NULL,
    synonyms    text[] NOT NULL DEFAULT '{}',
    status      text NOT NULL DEFAULT 'active' CHECK (status IN ('active','pending','merged')),
    merged_into text REFERENCES interests(id),
    usage_count integer NOT NULL DEFAULT 0       -- для веса редкости
);
CREATE INDEX interests_parent_idx ON interests (parent_id);

CREATE TABLE user_interests (
    user_id         uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    interest_id     text NOT NULL REFERENCES interests(id),
    level           text NOT NULL CHECK (level IN ('curious','doing','serious','pro','want_to_learn')),
    seeking_partner boolean NOT NULL DEFAULT false,
    details         jsonb NOT NULL DEFAULT '{}',  -- марка мотоцикла, разряд и т. п.
    PRIMARY KEY (user_id, interest_id)
);
CREATE INDEX user_interests_interest_idx ON user_interests (interest_id);

-- Цели и поиск ----------------------------------------------------------------

CREATE TABLE user_goals (
    user_id        uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    goal           text NOT NULL CHECK (goal IN ('romance','casual','friendship','hobby','talk','travel','likeminded')),
    active         boolean NOT NULL DEFAULT true,
    nearby_visible boolean NOT NULL DEFAULT false,   -- у каждой цели своя видимость в «Рядом»
    PRIMARY KEY (user_id, goal)
);

CREATE TABLE search_templates (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    goal          text NOT NULL,
    name          text NOT NULL,
    prefs         jsonb NOT NULL,                  -- обязательные и желательные критерии
    notify_nearby boolean NOT NULL DEFAULT false,
    min_score     smallint NOT NULL DEFAULT 60 CHECK (min_score BETWEEN 0 AND 100),
    daily_limit   smallint NOT NULL DEFAULT 5,
    quiet_from    time,
    quiet_to      time,
    created_at    timestamptz NOT NULL DEFAULT now()
);

-- Видимость и приватность -------------------------------------------------------

CREATE TABLE visibility_settings (
    user_id            uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    mode               text NOT NULL DEFAULT 'off' CHECK (mode IN ('off','foreground','background','timed','scheduled')),
    visible_until      timestamptz,
    radius_m           integer NOT NULL DEFAULT 1000 CHECK (radius_m IN (300,1000,3000,10000)),
    verified_only      boolean NOT NULL DEFAULT false,
    hide_from_contacts boolean NOT NULL DEFAULT false
);

-- Личные зоны: внутри них пользователь невидим. Храним центр, округлённый
-- до геоячейки, а не адрес.
CREATE TABLE private_zones (
    id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id   uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name      text NOT NULL,
    geohash   text NOT NULL,
    radius_m  integer NOT NULL CHECK (radius_m >= 500)
);

-- Хэши номеров из записной книжки для «скрыть от контактов».
CREATE TABLE contact_hashes (
    user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    phone_hash bytea NOT NULL,
    PRIMARY KEY (user_id, phone_hash)
);

-- Согласие и совпадения ---------------------------------------------------------

-- Одностороннее «Интересно». Вторая сторона о нём не узнаёт.
CREATE TABLE interests_expressed (
    from_user   uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    to_user     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    goal        text NOT NULL,
    interest_id text REFERENCES interests(id),     -- отмеченный общий интерес
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL DEFAULT now() + interval '24 hours',
    PRIMARY KEY (from_user, to_user, goal),
    CHECK (from_user <> to_user)
);

CREATE TABLE matches (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_a       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    user_b       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    goal         text NOT NULL,
    reveal_level smallint NOT NULL DEFAULT 2 CHECK (reveal_level BETWEEN 1 AND 4),
    created_at   timestamptz NOT NULL DEFAULT now(),
    ended_at     timestamptz,
    ended_by     uuid REFERENCES users(id),
    CHECK (user_a < user_b)                         -- одна пара — одна запись
);
CREATE UNIQUE INDEX matches_pair_active_idx ON matches (user_a, user_b, goal) WHERE ended_at IS NULL;

-- Временный обмен точной геопозицией (уровень 3). Сами координаты сюда
-- не пишутся — они живут только в Redis до stopped_at/until.
CREATE TABLE location_shares (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    match_id   uuid NOT NULL REFERENCES matches(id) ON DELETE CASCADE,
    from_user  uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    accepted   boolean NOT NULL DEFAULT false,
    until      timestamptz NOT NULL,
    stopped_at timestamptz,
    CHECK (until <= now() + interval '60 minutes')
);

CREATE TABLE messages (
    id         bigserial PRIMARY KEY,
    match_id   uuid REFERENCES matches(id) ON DELETE CASCADE,
    meetup_id  uuid,                                 -- общий чат компании
    sender     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind       text NOT NULL DEFAULT 'text' CHECK (kind IN ('text','photo','voice','system')),
    body       text,
    blurred    boolean NOT NULL DEFAULT false,      -- фильтр нежелательных изображений
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK ((match_id IS NULL) <> (meetup_id IS NULL))
);
CREATE INDEX messages_match_idx ON messages (match_id, created_at);

-- «Я на встрече»: если не отметиться вовремя, доверенный контакт получит SMS.
CREATE TABLE safety_checkins (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id        uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    match_id       uuid REFERENCES matches(id) ON DELETE SET NULL,
    trusted_phone  text NOT NULL,
    check_by       timestamptz NOT NULL,
    checked_in_at  timestamptz,
    alert_sent_at  timestamptz
);

-- Компании по интересам -------------------------------------------------------

CREATE TABLE meetups (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    organizer   uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    interest_id text NOT NULL REFERENCES interests(id),
    title       text NOT NULL,
    starts_at   timestamptz NOT NULL,
    area        text NOT NULL,                       -- район; точное место — participants only
    exact_place text,
    capacity    smallint NOT NULL CHECK (capacity BETWEEN 3 AND 6),
    beginners_welcome boolean NOT NULL DEFAULT false,
    created_at  timestamptz NOT NULL DEFAULT now(),
    cancelled_at timestamptz
);

CREATE TABLE meetup_participants (
    meetup_id uuid NOT NULL REFERENCES meetups(id) ON DELETE CASCADE,
    user_id   uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status    text NOT NULL DEFAULT 'requested' CHECK (status IN ('requested','approved','declined','left')),
    PRIMARY KEY (meetup_id, user_id)
);

ALTER TABLE messages
    ADD CONSTRAINT messages_meetup_fk FOREIGN KEY (meetup_id) REFERENCES meetups(id) ON DELETE CASCADE;

-- Безопасность и модерация ------------------------------------------------------

CREATE TABLE blocks (
    blocker    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    blocked    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (blocker, blocked)
);

CREATE TABLE reports (
    id          bigserial PRIMARY KEY,
    reporter    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    target      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    reason      text NOT NULL CHECK (reason IN ('threat','harassment','stalking','fake','spam','paid_services','explicit','other')),
    urgent      boolean GENERATED ALWAYS AS (reason IN ('threat','harassment','stalking')) STORED,
    comment     text,
    status      text NOT NULL DEFAULT 'open' CHECK (status IN ('open','in_review','resolved','rejected')),
    created_at  timestamptz NOT NULL DEFAULT now(),
    resolved_at timestamptz
);
CREATE INDEX reports_queue_idx ON reports (status, urgent DESC, created_at);

CREATE TABLE moderation_actions (
    id         bigserial PRIMARY KEY,
    target     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    action     text NOT NULL CHECK (action IN ('warn','hide_photo','restrict_nearby','suspend','ban')),
    report_id  bigint REFERENCES reports(id),
    moderator  text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- Журнал уведомлений «Рядом»: не чаще раза в 7 дней об одном человеке.
CREATE TABLE nearby_notifications (
    user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    other_user uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    sent_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, other_user, sent_at)
);
CREATE INDEX nearby_notifications_recent_idx ON nearby_notifications (user_id, sent_at DESC);
