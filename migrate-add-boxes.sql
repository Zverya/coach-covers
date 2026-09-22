-- Migration: let coaches request a box (gym) that isn't on the board yet.
-- Paste into Supabase → SQL Editor → Run. Safe to run more than once.

create table if not exists box_requests (
  id           uuid primary key default gen_random_uuid(),
  board_id     uuid not null references boards(id) on delete cascade,
  gym_name     text not null,
  link         text,
  requested_by text,
  status       text not null default 'pending' check (status in ('pending','added','declined')),
  created_at   timestamptz not null default now()
);
alter table box_requests enable row level security;
revoke all on box_requests from anon, authenticated;

-- A coach submits a gym + its public booking link.
create or replace function submit_box(p_token text, p_coach text, p_name text, p_link text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b_id uuid;
begin
  b_id := board_id_for(p_token);
  if b_id is null then return jsonb_build_object('ok', false, 'error', 'unknown_board'); end if;
  if coalesce(trim(p_name), '') = '' then return jsonb_build_object('ok', false, 'error', 'no_name'); end if;
  insert into box_requests (board_id, gym_name, link, requested_by)
  values (b_id, trim(p_name), nullif(trim(coalesce(p_link,'')), ''), nullif(trim(coalesce(p_coach,'')), ''));
  return jsonb_build_object('ok', true);
end $$;

-- Approver lists pending box requests.
create or replace function pending_boxes(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare b_id uuid; r text;
begin
  select br.b_id, br.role into b_id, r from board_role(p_token) br;
  if b_id is null or r <> 'admin' then return jsonb_build_object('ok', false, 'error', 'not_approver'); end if;
  return jsonb_build_object('ok', true, 'boxes', coalesce((
    select jsonb_agg(jsonb_build_object('id', id, 'gym', gym_name, 'link', link,
             'by', requested_by, 'status', status) order by created_at desc)
    from box_requests where board_id = b_id and status = 'pending'), '[]'::jsonb));
end $$;

-- Approver marks a request added / declined.
create or replace function resolve_box(p_token text, p_id uuid, p_status text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b_id uuid; r text; n int;
begin
  select br.b_id, br.role into b_id, r from board_role(p_token) br;
  if b_id is null or r <> 'admin' then return jsonb_build_object('ok', false, 'error', 'not_approver'); end if;
  if p_status not in ('added','declined') then return jsonb_build_object('ok', false, 'error', 'bad_status'); end if;
  update box_requests set status = p_status where id = p_id and board_id = b_id and status = 'pending';
  get diagnostics n = row_count;
  return jsonb_build_object('ok', n > 0);
end $$;

revoke all on function submit_box(text,text,text,text)  from public;
revoke all on function pending_boxes(text)              from public;
revoke all on function resolve_box(text,uuid,text)      from public;
grant execute on function submit_box(text,text,text,text) to anon, authenticated;
grant execute on function pending_boxes(text)             to anon, authenticated;
grant execute on function resolve_box(text,uuid,text)     to anon, authenticated;

-- ---- per-coach box selection, stored in the database (survives device changes) ----
create table if not exists coach_prefs (
  board_id   uuid not null references boards(id) on delete cascade,
  coach_name text not null,
  boxes      jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (board_id, coach_name)
);
alter table coach_prefs enable row level security;
revoke all on coach_prefs from anon, authenticated;

-- Save which boxes a coach coaches at.
create or replace function set_coach_boxes(p_token text, p_coach text, p_boxes jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b_id uuid;
begin
  b_id := board_id_for(p_token);
  if b_id is null then return jsonb_build_object('ok', false, 'error', 'unknown_board'); end if;
  if coalesce(trim(p_coach), '') = '' then return jsonb_build_object('ok', false, 'error', 'no_coach'); end if;
  insert into coach_prefs (board_id, coach_name, boxes, updated_at)
  values (b_id, trim(p_coach), coalesce(p_boxes, '[]'::jsonb), now())
  on conflict (board_id, coach_name)
    do update set boxes = excluded.boxes, updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

-- Read a coach's saved boxes.
create or replace function get_coach_boxes(p_token text, p_coach text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare b_id uuid; v jsonb;
begin
  b_id := board_id_for(p_token);
  if b_id is null then return jsonb_build_object('ok', false, 'error', 'unknown_board'); end if;
  select boxes into v from coach_prefs where board_id = b_id and coach_name = trim(p_coach);
  return jsonb_build_object('ok', true, 'boxes', coalesce(v, '[]'::jsonb));
end $$;

revoke all on function set_coach_boxes(text,text,jsonb) from public;
revoke all on function get_coach_boxes(text,text)       from public;
grant execute on function set_coach_boxes(text,text,jsonb) to anon, authenticated;
grant execute on function get_coach_boxes(text,text)       to anon, authenticated;

select 'migration complete' as status;
