-- «Скрыть меня от контактов». Номера храним только как HMAC с секретом сервера:
-- по утечке базы их не перебрать. Ключ своего номера считаем при регистрации.
ALTER TABLE users ADD COLUMN phone_key bytea;
CREATE INDEX contact_hashes_hash_idx ON contact_hashes (phone_hash);

ALTER TABLE consents DROP CONSTRAINT consents_kind_check;
ALTER TABLE consents ADD CONSTRAINT consents_kind_check CHECK (kind IN (
    'personal_data', 'special_category', 'geolocation', 'terms',
    'contacts'  -- загрузка хешей номеров из записной книжки
));
