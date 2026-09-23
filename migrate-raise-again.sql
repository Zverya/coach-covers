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
