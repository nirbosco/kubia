-- ============================================================
-- עדכון 2 · 24.8.2026
-- (א) שליטה במשחק: חזרה ללובי (השהיה) וסיום משחק
-- (ב) בחירה בפתיחה: קלף שיצא נעלם מהחבילה, או יכול לחזור
-- ============================================================

-- ---------- מצב מסך חדש ----------
alter table kubia_rooms drop constraint if exists kubia_rooms_screen_check;
alter table kubia_rooms add constraint kubia_rooms_screen_check
  check (screen in ('lobby','table','deck','card','ended'));

-- ---------- עמודות חדשות ----------
-- allow_repeat: אמת = קלף שיצא חוזר לחבילה ויכול לצאת שוב.
--               שקר (ברירת מחדל) = קלף שיצא נעלם עד שהחבילה נגמרת ונטרפת.
alter table kubia_rooms add column if not exists allow_repeat boolean not null default false;
-- answered_total: מונה תשובות אמיתי, נחוץ כי במצב חזרות אותה שאלה יכולה להיענות יותר מפעם
alter table kubia_rooms add column if not exists answered_total int not null default 0;

-- מסנכרן את המונה לחדרים קיימים
update kubia_rooms r
   set answered_total = (select count(*) from kubia_room_used u where u.room_id = r.id and u.answered)
 where answered_total = 0;

-- ---------- מצב חדר ----------
create or replace function kubia_get_state(p_code text)
returns json
language plpgsql security definer set search_path = public as $$
declare v json;
begin
  update kubia_rooms set last_seen_at = now() where code = p_code;

  select json_build_object(
    'id', r.id, 'code', r.code, 'audience', r.audience, 'dice_mode', r.dice_mode,
    'allow_repeat', r.allow_repeat,
    'screen', r.screen, 'category', r.current_category,
    'question_id', r.current_question, 'question_text', q.text,
    'seq', r.seq, 'answered_count', r.answered_total
  )
  into v
  from kubia_rooms r
  left join kubia_questions q on q.id = r.current_question
  where r.code = p_code;

  return v;
end;
$$;

-- ---------- יצירת חדר עם הבחירה החדשה ----------
drop function if exists kubia_create_room(text, text);

create or replace function kubia_create_room(p_audience text, p_dice_mode text, p_allow_repeat boolean default false)
returns text
language plpgsql security definer set search_path = public as $$
declare v_code text; v_try int := 0;
begin
  if p_audience not in ('teachers','leaders') then raise exception 'bad audience'; end if;
  if p_dice_mode not in ('virtual','physical') then raise exception 'bad dice mode'; end if;

  perform kubia_gc();

  loop
    v_try := v_try + 1;
    v_code := lpad((1000 + floor(random() * 9000))::int::text, 4, '0');
    exit when not exists (select 1 from kubia_rooms where code = v_code);
    if v_try > 50 then raise exception 'no free room code'; end if;
  end loop;

  insert into kubia_rooms (code, audience, dice_mode, allow_repeat)
  values (v_code, p_audience, p_dice_mode, coalesce(p_allow_repeat, false));
  return v_code;
end;
$$;

-- ---------- שליפת קלף, מכבדת את מצב החזרות ----------
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

  if v_room.allow_repeat then
    -- מצב חזרות: כל הקטגוריה זמינה בכל שליפה
    select q.id into v_qid
      from kubia_questions q
     where q.visible
       and q.category = v_room.current_category
       and q.audience in ('general', v_room.audience)
       and (q.id is distinct from v_room.current_question) -- לא אותו קלף פעמיים ברצף
     order by random() limit 1;

    if v_qid is null then -- קטגוריה עם שאלה אחת בלבד
      select q.id into v_qid from kubia_questions q
       where q.visible and q.category = v_room.current_category
         and q.audience in ('general', v_room.audience)
       order by random() limit 1;
    end if;
  else
    -- מצב היעלמות: רק מה שלא נוצל בחדר
    select q.id into v_qid
      from kubia_questions q
     where q.visible
       and q.category = v_room.current_category
       and q.audience in ('general', v_room.audience)
       and not exists (select 1 from kubia_room_used u where u.room_id = v_room.id and u.question_id = q.id)
     order by random() limit 1;

    if v_qid is null then
      delete from kubia_room_used u using kubia_questions q
       where u.room_id = v_room.id and q.id = u.question_id and q.category = v_room.current_category;
      v_reshuffled := true;

      select q.id into v_qid from kubia_questions q
       where q.visible and q.category = v_room.current_category
         and q.audience in ('general', v_room.audience)
       order by random() limit 1;
    end if;
  end if;

  if v_qid is null then return kubia_get_state(p_code); end if;

  insert into kubia_room_used (room_id, question_id) values (v_room.id, v_qid)
    on conflict do nothing;

  update kubia_rooms
     set current_question = v_qid, screen = 'card', seq = seq + 1, last_seen_at = now()
   where id = v_room.id;

  v_state := kubia_get_state(p_code);
  return jsonb_set(v_state::jsonb, '{reshuffled}', to_jsonb(v_reshuffled))::json;
end;
$$;

-- ---------- סגירת קלף, עם מונה תשובות אמיתי ----------
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
           answered_total = answered_total + 1, seq = seq + 1, last_seen_at = now()
     where id = v_room.id;
    return kubia_get_state(p_code);

  elsif p_action = 'reroll' then
    update kubia_rooms
       set screen = 'table', current_question = null, current_category = null,
           seq = seq + 1, last_seen_at = now()
     where id = v_room.id;
    return kubia_get_state(p_code);

  else
    update kubia_rooms set seq = seq + 1, last_seen_at = now() where id = v_room.id;
    return kubia_draw(p_code, v_room.seq + 1);
  end if;
end;
$$;

-- ---------- שליטה במשחק ----------

-- חזרה ללובי: השהיה, ומאפשר למצטרפים חדשים להיכנס.
-- הקלפים שנוצלו והמונה נשמרים, כך שהמשחק ממשיך מאותה נקודה.
create or replace function kubia_to_lobby(p_code text, p_seq bigint)
returns json
language plpgsql security definer set search_path = public as $$
begin
  update kubia_rooms
     set screen = 'lobby', current_question = null, current_category = null,
         seq = seq + 1, last_seen_at = now()
   where code = p_code and seq = p_seq and screen <> 'ended';
  return kubia_get_state(p_code);
end;
$$;

-- סיום משחק: כל המכשירים בחדר עוברים למסך סיום.
create or replace function kubia_end(p_code text, p_seq bigint)
returns json
language plpgsql security definer set search_path = public as $$
begin
  update kubia_rooms
     set screen = 'ended', current_question = null, current_category = null,
         seq = seq + 1, last_seen_at = now()
   where code = p_code and seq = p_seq;
  return kubia_get_state(p_code);
end;
$$;

-- ---------- הרשאות ----------
grant execute on function
  kubia_create_room(text,text,boolean),
  kubia_to_lobby(text,bigint),
  kubia_end(text,bigint)
to anon, authenticated;

select 'ok' as status;
