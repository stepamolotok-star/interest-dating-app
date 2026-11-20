-- Удаление аккаунта: журнал модерации не должен мешать удалить жалобу,
-- если её автор удалил аккаунт. Само решение о нарушителе остаётся.
ALTER TABLE moderation_actions DROP CONSTRAINT IF EXISTS moderation_actions_report_id_fkey;
ALTER TABLE moderation_actions ADD CONSTRAINT moderation_actions_report_id_fkey
    FOREIGN KEY (report_id) REFERENCES reports(id) ON DELETE SET NULL;
