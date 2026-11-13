-- Город — из справочника (код ФИАС), а не свободным текстом: «Чита» и «г. Чита» —
-- один город, а одноимённые города в разных регионах — разные.
ALTER TABLE profiles ADD COLUMN city_id text;
CREATE INDEX profiles_city_id_idx ON profiles (city_id);
