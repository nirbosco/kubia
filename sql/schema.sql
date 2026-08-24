-- ============================================================
-- עבר · הווה · עתיד — סכמה, פונקציות והרשאות
-- פרויקט Supabase: hotamnemi (ndrhiikczkbosentclnh)
-- כל האובייקטים בקידומת kubia_ . אין לגעת בטבלאות בלי קידומת.
-- מיפוי קטגוריות (כמו בחבילה המודפסת):
--   1 עבר אישי · 2 עבר מקצועי · 3 עתיד מקצועי
--   4 עתיד אישי · 5 הווה אישי · 6 הווה מקצועי
-- ============================================================

-- ---------- טבלאות ----------

create table if not exists kubia_questions (
  id          uuid primary key default gen_random_uuid(),
  text        text not null check (char_length(btrim(text)) between 3 and 200),
  category    smallint not null check (category between 1 and 6),
  audience    text not null default 'general' check (audience in ('general','teachers','leaders')),
  visible     boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists kubia_rooms (
  id                uuid primary key default gen_random_uuid(),
  code              text not null unique,
  audience          text not null check (audience in ('teachers','leaders')),
  dice_mode         text not null default 'virtual' check (dice_mode in ('virtual','physical')),
  screen            text not null default 'lobby' check (screen in ('lobby','table','deck','card')),
  current_category  smallint check (current_category between 1 and 6),
  current_question  uuid references kubia_questions(id),
  seq               bigint not null default 0,
  created_at        timestamptz not null default now(),
  last_seen_at      timestamptz not null default now()
);

create table if not exists kubia_room_used (
  room_id      uuid not null references kubia_rooms(id) on delete cascade,
  question_id  uuid not null references kubia_questions(id),
  answered     boolean not null default false,
  drawn_at     timestamptz not null default now(),
  primary key (room_id, question_id)
);

create index if not exists kubia_questions_pick_idx on kubia_questions (category, audience) where visible;
create index if not exists kubia_rooms_code_idx      on kubia_rooms (code);
create index if not exists kubia_rooms_stale_idx     on kubia_rooms (last_seen_at);

-- ---------- עזר פנימי ----------

-- ניקוי חדרים שלא נגעו בהם 24 שעות. נקרא בעצלנות ביצירת חדר.
create or replace function kubia_gc() returns void
language sql security definer set search_path = public as $$
  delete from kubia_rooms where last_seen_at < now() - interval '24 hours';
$$;

-- ---------- פונקציות ציבוריות ----------

create or replace function kubia_create_room(p_audience text, p_dice_mode text)
returns text
language plpgsql security definer set search_path = public as $$
declare v_code text; v_try int := 0;
begin
  if p_audience not in ('teachers','leaders') then
    raise exception 'bad audience';
  end if;
  if p_dice_mode not in ('virtual','physical') then
    raise exception 'bad dice mode';
  end if;

  perform kubia_gc();

  loop
    v_try := v_try + 1;
    v_code := lpad((1000 + floor(random() * 9000))::int::text, 4, '0');
    exit when not exists (select 1 from kubia_rooms where code = v_code);
    if v_try > 50 then raise exception 'no free room code'; end if;
  end loop;

  insert into kubia_rooms (code, audience, dice_mode) values (v_code, p_audience, p_dice_mode);
  return v_code;
end;
$$;

create or replace function kubia_get_state(p_code text)
returns json
language plpgsql security definer set search_path = public as $$
declare v json;
begin
  update kubia_rooms set last_seen_at = now() where code = p_code;

  select json_build_object(
    'id', r.id,
    'code', r.code,
    'audience', r.audience,
    'dice_mode', r.dice_mode,
    'screen', r.screen,
    'category', r.current_category,
    'question_id', r.current_question,
    'question_text', q.text,
    'seq', r.seq,
    'answered_count', (select count(*) from kubia_room_used u where u.room_id = r.id and u.answered)
  )
  into v
  from kubia_rooms r
  left join kubia_questions q on q.id = r.current_question
  where r.code = p_code;

  return v; -- null אם אין חדר כזה
end;
$$;

-- כל שאלות המאגר הרלוונטיות לחדר, לקאש בצד הלקוח
create or replace function kubia_room_questions(p_code text)
returns setof kubia_questions
language sql security definer set search_path = public as $$
  select q.* from kubia_questions q
  join kubia_rooms r on r.code = p_code
  where q.visible and q.audience in ('general', r.audience);
$$;

-- הטלת קובייה: ההגרלה בשרת, לא בלקוח
create or replace function kubia_roll(p_code text, p_seq bigint)
returns json
language plpgsql security definer set search_path = public as $$
declare v_face smallint;
begin
  v_face := 1 + floor(random() * 6);
  update kubia_rooms
     set current_category = v_face,
         current_question = null,
         screen = 'deck',
         seq = seq + 1,
         last_seen_at = now()
   where code = p_code and seq = p_seq;

  if not found then return kubia_get_state(p_code); end if; -- פעולה מאוחרת, נדחית בשקט
  return kubia_get_state(p_code);
end;
$$;

-- קובייה פיזית בחדר: מקישים על הספרה שיצאה
create or replace function kubia_pick_face(p_code text, p_seq bigint, p_face smallint)
returns json
language plpgsql security definer set search_path = public as $$
begin
  if p_face < 1 or p_face > 6 then raise exception 'bad face'; end if;

  update kubia_rooms
     set current_category = p_face,
         current_question = null,
         screen = 'deck',
         seq = seq + 1,
         last_seen_at = now()
   where code = p_code and seq = p_seq;

  return kubia_get_state(p_code);
end;
$$;

-- שליפת קלף: בחירה אקראית בשרת מתוך מה שלא נוצל בחדר
create or replace function kubia_draw(p_code text, p_seq bigint)
returns json
language plpgsql security definer set search_path = public as $$
declare
  v_room kubia_rooms;
  v_qid uuid;
  v_reshuffled boolean := false;
  v_state json;
begin
  select * into v_room from kubia_rooms where code = p_code and seq = p_seq;
  if not found then return kubia_get_state(p_code); end if;
  if v_room.current_category is null then return kubia_get_state(p_code); end if;

  select q.id into v_qid
    from kubia_questions q
   where q.visible
     and q.category = v_room.current_category
     and q.audience in ('general', v_room.audience)
     and not exists (select 1 from kubia_room_used u where u.room_id = v_room.id and u.question_id = q.id)
   order by random() limit 1;

  -- החבילה נגמרה: טורפים מחדש את הקטגוריה הזאת
  if v_qid is null then
    delete from kubia_room_used u
     using kubia_questions q
     where u.room_id = v_room.id and q.id = u.question_id and q.category = v_room.current_category;
    v_reshuffled := true;

    select q.id into v_qid
      from kubia_questions q
     where q.visible
       and q.category = v_room.current_category
       and q.audience in ('general', v_room.audience)
     order by random() limit 1;
  end if;

  if v_qid is null then return kubia_get_state(p_code); end if; -- אין שאלות בקטגוריה בכלל

  insert into kubia_room_used (room_id, question_id) values (v_room.id, v_qid)
    on conflict do nothing;

  update kubia_rooms
     set current_question = v_qid, screen = 'card', seq = seq + 1, last_seen_at = now()
   where id = v_room.id;

  v_state := kubia_get_state(p_code);
  return jsonb_set(v_state::jsonb, '{reshuffled}', to_jsonb(v_reshuffled))::json;
end;
$$;

-- סגירת קלף: answered / swap / reroll
create or replace function kubia_resolve(p_code text, p_seq bigint, p_action text)
returns json
language plpgsql security definer set search_path = public as $$
declare v_room kubia_rooms;
begin
  if p_action not in ('answered','swap','reroll') then raise exception 'bad action'; end if;

  select * into v_room from kubia_rooms where code = p_code and seq = p_seq;
  if not found then return kubia_get_state(p_code); end if;

  if p_action = 'answered' then
    update kubia_room_used set answered = true
     where room_id = v_room.id and question_id = v_room.current_question;
    update kubia_rooms
       set screen = 'table', current_question = null, current_category = null,
           seq = seq + 1, last_seen_at = now()
     where id = v_room.id;
    return kubia_get_state(p_code);

  elsif p_action = 'reroll' then
    update kubia_rooms
       set screen = 'table', current_question = null, current_category = null,
           seq = seq + 1, last_seen_at = now()
     where id = v_room.id;
    return kubia_get_state(p_code);

  else -- swap: הקלף הנוכחי נשאר מנוצל, נשלף אחר מאותה קטגוריה
    update kubia_rooms set seq = seq + 1, last_seen_at = now() where id = v_room.id;
    return kubia_draw(p_code, v_room.seq + 1);
  end if;
end;
$$;

-- התחלת משחק מהלובי
create or replace function kubia_start(p_code text, p_seq bigint)
returns json
language plpgsql security definer set search_path = public as $$
begin
  update kubia_rooms
     set screen = 'table', seq = seq + 1, last_seen_at = now()
   where code = p_code and seq = p_seq and screen = 'lobby';
  return kubia_get_state(p_code);
end;
$$;

-- ---------- דשבורד ----------

create or replace function kubia_add_question(p_text text, p_category smallint, p_audience text)
returns kubia_questions
language plpgsql security definer set search_path = public as $$
declare v_row kubia_questions;
begin
  if p_category < 1 or p_category > 6 then raise exception 'bad category'; end if;
  if p_audience not in ('general','teachers','leaders') then raise exception 'bad audience'; end if;
  if char_length(btrim(p_text)) < 3 then raise exception 'text too short'; end if;

  insert into kubia_questions (text, category, audience)
  values (btrim(p_text), p_category, p_audience)
  returning * into v_row;
  return v_row;
end;
$$;

-- הסתרה והצגה בלבד. אין מחיקה מכוונת, כדי שדשבורד פתוח לא יוכל להרוס את המאגר.
create or replace function kubia_set_visible(p_id uuid, p_visible boolean)
returns kubia_questions
language plpgsql security definer set search_path = public as $$
declare v_row kubia_questions;
begin
  update kubia_questions set visible = p_visible where id = p_id returning * into v_row;
  return v_row;
end;
$$;

create or replace function kubia_edit_question(p_id uuid, p_text text, p_category smallint, p_audience text)
returns kubia_questions
language plpgsql security definer set search_path = public as $$
declare v_row kubia_questions;
begin
  if p_category < 1 or p_category > 6 then raise exception 'bad category'; end if;
  if p_audience not in ('general','teachers','leaders') then raise exception 'bad audience'; end if;
  if char_length(btrim(p_text)) < 3 then raise exception 'text too short'; end if;

  update kubia_questions
     set text = btrim(p_text), category = p_category, audience = p_audience
   where id = p_id returning * into v_row;
  return v_row;
end;
$$;

-- ---------- אבטחה ----------
-- RLS דולק על הכל. לאנונימי אין כתיבה ישירה בשום טבלה,
-- וגם לא קריאה של טבלאות החדרים. כל פעולה עוברת דרך RPC.

alter table kubia_questions  enable row level security;
alter table kubia_rooms      enable row level security;
alter table kubia_room_used  enable row level security;

drop policy if exists kubia_questions_read on kubia_questions;
create policy kubia_questions_read on kubia_questions
  for select to anon, authenticated using (true);

drop policy if exists kubia_rooms_read on kubia_rooms;
create policy kubia_rooms_read on kubia_rooms
  for select to anon, authenticated using (true);

revoke all on kubia_questions  from anon, authenticated;
revoke all on kubia_rooms      from anon, authenticated;
revoke all on kubia_room_used  from anon, authenticated;
grant select on kubia_questions to anon, authenticated;
grant select on kubia_rooms     to anon, authenticated;

grant execute on function
  kubia_create_room(text,text),
  kubia_get_state(text),
  kubia_room_questions(text),
  kubia_roll(text,bigint),
  kubia_pick_face(text,bigint,smallint),
  kubia_draw(text,bigint),
  kubia_resolve(text,bigint,text),
  kubia_start(text,bigint),
  kubia_add_question(text,smallint,text),
  kubia_set_visible(uuid,boolean),
  kubia_edit_question(uuid,text,smallint,text)
to anon, authenticated;

revoke execute on function kubia_gc() from anon, authenticated;

-- ---------- זמן אמת ----------
-- כל שינוי בשורת החדר נדחף לכל המכשירים המחוברים.
alter publication supabase_realtime add table kubia_rooms;
