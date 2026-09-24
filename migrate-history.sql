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
