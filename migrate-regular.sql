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
