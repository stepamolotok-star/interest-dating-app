-- Фильтры по целям и «Пропустить» в ленте.

-- Портрет искомого человека для каждой цели (JSON формата matching.Prefs).
CREATE TABLE goal_prefs (
    user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    goal       text NOT NULL,
    prefs      jsonb NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, goal)
);

-- «Пропустить»: человек не показывается снова 30 дней.
CREATE TABLE skips (
    viewer     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    target     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    goal       text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (viewer, target, goal)
);

CREATE INDEX profiles_city_idx ON profiles (lower(city));
CREATE INDEX user_goals_active_idx ON user_goals (goal) WHERE active;
CREATE INDEX interests_expressed_to_idx ON interests_expressed (to_user, goal);
