-- Everything pending as of 2026-09-24, in order. Safe to run more than once.

-- ===== migrate-raise-again.sql =====
-- A class whose request was removed (cancelled) or turned down (rejected)
-- could never be asked for again: the unique (board_id, shift_key) row was
-- still there and raise_cover's "do nothing" tripped over it. Re-raising now
-- reopens that row cleanly. Anything genuinely live still answers
-- already_requested.
create or replace function raise_cover(p_token text, p_key text, p_coach text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b_id uuid; s shifts%rowtype; r_id uuid;
begin
  b_id := board_id_for(p_token);
  if b_id is null then return jsonb_build_object('ok', false, 'error', 'unknown_board'); end if;
  if coalesce(trim(p_coach), '') = '' then return jsonb_build_object('ok', false, 'error', 'no_name'); end if;

  select * into s from shifts where board_id = b_id and shift_key = p_key;
  if not found then return jsonb_build_object('ok', false, 'error', 'unknown_shift'); end if;

  insert into requests (board_id, shift_key, shift_date, shift_time, box, klass,
                        original_coach, status, created_by)
  values (b_id, s.shift_key, s.shift_date, s.shift_time, s.box, s.klass,
          coalesce(s.coach, p_coach), 'open', p_coach)
  on conflict (board_id, shift_key) do update
     set status = 'open', created_by = excluded.created_by,
         original_coach = excluded.original_coach,
         shift_date = excluded.shift_date, shift_time = excluded.shift_time,
         box = excluded.box, klass = excluded.klass,
         claimed_by = null, claimed_at = null,
         approved_at = null, approved_by = null, decision_note = null,
         checked_coach = null, checked_at = null
   where requests.status in ('cancelled', 'rejected')
  returning id into r_id;

  if r_id is null then
    return jsonb_build_object('ok', false, 'error', 'already_requested');
  end if;
  return jsonb_build_object('ok', true, 'id', r_id);
end $$;

-- ===== migrate-regular.sql =====
-- Regular shifts: the weekly pattern a coach confirms during onboarding (or from
-- their profile). Saved with the coach's other preferences so it follows them
-- across devices. The board pencils these into the calendar for the weeks Arbox
-- hasn't published yet; once Arbox publishes a date, Arbox decides.
alter table coach_prefs add column if not exists regular jsonb not null default '[]'::jsonb;

create or replace function set_coach_regular(p_token text, p_coach text, p_regular jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b_id uuid;
begin
  b_id := board_id_for(p_token);
  if b_id is null then return jsonb_build_object('ok', false, 'error', 'unknown_board'); end if;
  if coalesce(trim(p_coach), '') = '' then return jsonb_build_object('ok', false, 'error', 'no_coach'); end if;
  insert into coach_prefs (board_id, coach_name, regular, updated_at)
  values (b_id, trim(p_coach), coalesce(p_regular, '[]'::jsonb), now())
  on conflict (board_id, coach_name)
    do update set regular = excluded.regular, updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

-- get_coach_boxes now also returns the regular pattern.
create or replace function get_coach_boxes(p_token text, p_coach text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare b_id uuid; v_boxes jsonb; v_reg jsonb;
begin
  b_id := board_id_for(p_token);
  if b_id is null then return jsonb_build_object('ok', false, 'error', 'unknown_board'); end if;
  select boxes, regular into v_boxes, v_reg from coach_prefs where board_id = b_id and coach_name = trim(p_coach);
  return jsonb_build_object('ok', true, 'boxes', coalesce(v_boxes, '[]'::jsonb), 'regular', coalesce(v_reg, '[]'::jsonb));
end $$;

revoke all on function set_coach_regular(text,text,jsonb) from public;
grant execute on function set_coach_regular(text,text,jsonb) to anon, authenticated;

-- ===== migrate-future-cover.sql =====
-- Cover for an expected class: a regular slot Arbox hasn't published yet.
-- The request is keyed "reg|date|time|box" until the nightly push sees the real
-- class, then adopts its key so everything else (taking it, the admin's list,
-- the check) works exactly as for a published class.
-- This file also carries the nightly-check rules from migrate-scan-infer.sql,
-- so it is safe to run on its own.

create or replace function raise_future_cover(p_token text, p_key text, p_coach text,
                                              p_date date, p_time text, p_box text, p_klass text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b_id uuid; s shifts%rowtype; r_id uuid; k text;
begin
  b_id := board_id_for(p_token);
  if b_id is null then return jsonb_build_object('ok', false, 'error', 'unknown_board'); end if;
  if coalesce(trim(p_coach), '') = '' then return jsonb_build_object('ok', false, 'error', 'no_name'); end if;
  if p_key not like 'reg|%' then return jsonb_build_object('ok', false, 'error', 'bad_key'); end if;

  -- if Arbox has this class after all, ask on the real one
  select * into s from shifts
   where board_id = b_id and shift_date = p_date and left(shift_time,5) = left(p_time,5) and box = p_box
   order by (coach = p_coach) desc limit 1;
  k := coalesce(s.shift_key, p_key);

  insert into requests (board_id, shift_key, shift_date, shift_time, box, klass,
                        original_coach, status, created_by)
  values (b_id, k, p_date, left(p_time,5), p_box, coalesce(s.klass, p_klass),
          coalesce(s.coach, p_coach), 'open', p_coach)
  on conflict (board_id, shift_key) do update
     set status = 'open', created_by = excluded.created_by, original_coach = excluded.original_coach,
         claimed_by = null, claimed_at = null, approved_at = null, approved_by = null, decision_note = null,
         checked_coach = null, checked_at = null
   where requests.status in ('cancelled', 'rejected')
  returning id into r_id;
  if r_id is null then return jsonb_build_object('ok', false, 'error', 'already_requested'); end if;
  return jsonb_build_object('ok', true, 'id', r_id, 'key', k);
end $$;
revoke all on function raise_future_cover(text,text,text,date,text,text,text) from public;
grant execute on function raise_future_cover(text,text,text,date,text,text,text) to anon, authenticated;

create or replace function push_shifts(p_admin text, p_shifts jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b_id uuid; n int;
begin
  select id into b_id from boards where admin_token = p_admin;
  if b_id is null then return jsonb_build_object('ok', false, 'error', 'unknown_admin'); end if;

  insert into shifts (board_id, shift_key, shift_date, shift_time, box, klass, coach)
  select b_id, x->>'key', (x->>'date')::date, x->>'time',
         x->>'box', x->>'klass', x->>'coach'
    from jsonb_array_elements(p_shifts) as x
  on conflict (board_id, shift_key) do update
    set coach = excluded.coach, klass = excluded.klass;
  get diagnostics n = row_count;

  -- expected classes Arbox has now published: adopt the real class
  update requests r
     set shift_key = s.shift_key, klass = coalesce(s.klass, r.klass)
    from shifts s
   where r.board_id = b_id and r.shift_key like 'reg|%'
     and s.board_id = r.board_id and s.shift_date = r.shift_date
     and left(s.shift_time,5) = left(r.shift_time,5) and s.box = r.box
     and not exists (select 1 from requests q where q.board_id = r.board_id and q.shift_key = s.shift_key);

  -- expected classes on a day Arbox has published without them: nothing to cover
  update requests r
     set status = 'cancelled', checked_at = now()
   where r.board_id = b_id and r.shift_key like 'reg|%' and r.status in ('open','claimed')
     and exists (select 1 from shifts s where s.board_id = r.board_id and s.box = r.box and s.shift_date = r.shift_date);

  -- the schedule is the truth
  update requests r
     set status = case
           when trim(coalesce(s.coach,'')) <> ''
            and trim(s.coach) <> trim(coalesce(r.original_coach,''))   then 'verified'
           when r.status in ('approved','mismatch')                    then 'mismatch'
           else r.status
         end,
         claimed_by = case
           when trim(coalesce(s.coach,'')) <> ''
            and trim(s.coach) <> trim(coalesce(r.original_coach,''))   then trim(s.coach)
           else r.claimed_by
         end,
         claimed_at = case
           when trim(coalesce(s.coach,'')) <> ''
            and trim(s.coach) <> trim(coalesce(r.original_coach,''))   then coalesce(r.claimed_at, now())
           else r.claimed_at
         end,
         checked_coach = s.coach, checked_at = now()
    from shifts s
   where s.board_id = r.board_id and s.shift_key = r.shift_key
     and r.board_id = b_id
     and r.status in ('open','claimed','approved','mismatch','verified');

  return jsonb_build_object('ok', true, 'written', n);
end $$;

-- ===== migrate-history.sql =====
-- A coach's own past classes (last 90 days) plus which days each box has
-- published, so the regular-shift detection can look back further than the
-- calendar needs to. Small: one coach's rows and a box/day list.
create or replace function coach_history(p_token text, p_coach text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare b_id uuid;
begin
  b_id := board_id_for(p_token);
  if b_id is null then return jsonb_build_object('ok', false, 'error', 'unknown_board'); end if;
  return jsonb_build_object(
    'ok', true,
    'shifts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'key', shift_key, 'date', shift_date, 'time', shift_time,
        'box', box, 'klass', klass, 'coach', coach) order by shift_date, shift_time)
      from shifts
      where board_id = b_id and coach = trim(p_coach)
        and shift_date >= current_date - 90 and shift_date < current_date - 1
    ), '[]'::jsonb),
    'days', coalesce((
      select jsonb_agg(jsonb_build_object('box', box, 'date', d) order by box, d)
      from (select distinct box, shift_date as d from shifts
             where board_id = b_id and shift_date >= current_date - 90 and shift_date < current_date - 1) t
    ), '[]'::jsonb)
  );
end $$;
revoke all on function coach_history(text,text) from public;
grant execute on function coach_history(text,text) to anon, authenticated;

