-- Отдельная цель «Серьёзные отношения и семья».
ALTER TABLE user_goals DROP CONSTRAINT user_goals_goal_check;
ALTER TABLE user_goals ADD CONSTRAINT user_goals_goal_check
    CHECK (goal IN ('family','romance','casual','friendship','hobby','talk','travel','likeminded'));

-- Старое поле «дети: есть / хочу / нет» разделено на два: has_kids и wants_kids.
UPDATE profiles SET habits = (habits - 'kids') || jsonb_build_object('has_kids', 'yes')
    WHERE habits->>'kids' = 'has';
UPDATE profiles SET habits = (habits - 'kids') || jsonb_build_object('wants_kids', 'yes')
    WHERE habits->>'kids' = 'wants';
UPDATE profiles SET habits = (habits - 'kids') || jsonb_build_object('has_kids', 'no')
    WHERE habits->>'kids' = 'no';
