-- Причина жалобы «похоже, что это несовершеннолетний»: срочная, модератор смотрит первой.
DROP INDEX reports_queue_idx;
ALTER TABLE reports DROP COLUMN urgent;
ALTER TABLE reports DROP CONSTRAINT reports_reason_check;
ALTER TABLE reports ADD CONSTRAINT reports_reason_check
    CHECK (reason IN ('threat','harassment','stalking','minor','fake','spam','paid_services','explicit','other'));
ALTER TABLE reports ADD COLUMN urgent boolean
    GENERATED ALWAYS AS (reason IN ('threat','harassment','stalking','minor')) STORED;
CREATE INDEX reports_queue_idx ON reports (status, urgent DESC, created_at);
