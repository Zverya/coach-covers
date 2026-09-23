-- Remove a cover request from the board (the board's "Remove" button).
-- Only while nobody has taken it; the coach who raised it, the coach it
-- belongs to, or a box admin. Cancelled rows are already left out of
-- board_state, so the class simply returns to plain "yours" on the calendar.
create or replace function cancel_cover(p_token text, p_request uuid, p_coach text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b_id uuid; r text; updated int;
begin
  select br.b_id, br.role into b_id, r from board_role(p_token) br;
  if b_id is null then return jsonb_build_object('ok', false, 'error', 'unknown_board'); end if;
  update requests
     set status = 'cancelled'
   where id = p_request and board_id = b_id and status = 'open'
     and (r in ('admin','box_admin') or created_by = p_coach or original_coach = p_coach);
  get diagnostics updated = row_count;
  if updated = 0 then return jsonb_build_object('ok', false, 'error', 'wrong_state'); end if;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function cancel_cover(text, uuid, text) to anon, authenticated;
