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
