-- Часовой пояс пользователя — для тихих часов уведомлений «Рядом».
ALTER TABLE profiles ADD COLUMN timezone text NOT NULL DEFAULT 'Europe/Moscow';
