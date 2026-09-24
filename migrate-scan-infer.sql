-- Nightly check, second thinking: the published schedule is the truth.
--   * A class that needed cover and now lists a different coach than the one
--     who asked  -> confirmed, and that coach is recorded as the one teaching
--     (whoever took it on the board, or straight in Arbox).
--   * A class you took that now lists you                -> confirmed (same rule).
--   * A class the admin marked done that still lists the original coach
--                                                          -> not updated.
--   * Anything else keeps its state; a slot with no coach tells us nothing.
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
