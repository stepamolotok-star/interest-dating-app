-- Вход через VK ID / Яндекс ID: незавершённые попытки входа (state → code_verifier).
-- Живут 10 минут. Токены провайдеров не храним: берём номер телефона и забываем.
CREATE TABLE oauth_states (
    state         text PRIMARY KEY,
    provider      text NOT NULL,
    code_verifier text NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX oauth_states_created_idx ON oauth_states (created_at);
