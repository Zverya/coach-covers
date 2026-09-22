-- Coach Covers — Supabase schema
-- Paste this whole file into Supabase → SQL Editor → Run.
-- Safe to run more than once.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- tables
create table if not exists boards (
  id           uuid primary key default gen_random_uuid(),
  name         text not null,
  share_token  text not null unique,   -- goes in the link you send coaches
  admin_token  text not null unique,   -- only you and Claude hold this
  created_at   timestamptz not null default now()
);

create table if not exists shifts (
  id         uuid primary key default gen_random_uuid(),
  board_id   uuid not null references boards(id) on delete cascade,
  shift_key  text not null,            -- date|time|box  (stable across re-pulls)
  shift_date date not null,
  shift_time text not null,
  box        text not null,
  klass      text,
  coach      text,
  unique (board_id, shift_key)
);
create index if not exists shifts_board_date on shifts(board_id, shift_date);

create table if not exists requests (
  id             uuid primary key default gen_random_uuid(),
  board_id       uuid not null references boards(id) on delete cascade,
  shift_key      text not null,
  shift_date     date not null,
  shift_time     text not null,
  box            text not null,
  klass          text,
  original_coach text,
  status         text not null default 'open'
                 check (status in ('open','claimed','sent','verified','mismatch','cancelled')),
  claimed_by     text,
  claimed_at     timestamptz,
  sent_at        timestamptz,
  checked_coach  text,
  checked_at     timestamptz,
  created_by     text,
  created_at     timestamptz not null default now(),
  unique (board_id, shift_key)
);
create index if not exists requests_board_status on requests(board_id, status);

-- ------------------------------------------------------- lock the tables
-- RLS on with NO policies means the anon key cannot read or write these
-- tables directly. Everything goes through the functions below, which run
-- as their owner and check the token themselves.
alter table boards   enable row level security;
alter table shifts   enable row level security;
alter table requests enable row level security;

revoke all on boards, shifts, requests from anon, authenticated;

-- ------------------------------------------------------------- functions
create or replace function board_id_for(p_token text)
returns uuid language sql stable security definer set search_path = public as $$
  select id from boards where share_token = p_token;
$$;

-- Everything the page needs, in one round trip.
create or replace function board_state(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare b_id uuid; out jsonb;
begin
  b_id := board_id_for(p_token);
  if b_id is null then
    return jsonb_build_object('ok', false, 'error', 'unknown_board');
  end if;
  select jsonb_build_object(
    'ok', true,
    'board', (select jsonb_build_object('name', name) from boards where id = b_id),
    'coaches', coalesce((
      select jsonb_agg(distinct coach order by coach)
      from shifts where board_id = b_id and coach is not null and coach <> ''
    ), '[]'::jsonb),
    'shifts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'key', shift_key, 'date', shift_date, 'time', shift_time,
        'box', box, 'klass', klass, 'coach', coach) order by shift_date, shift_time)
      from shifts where board_id = b_id and shift_date >= current_date - 1
    ), '[]'::jsonb),
    'requests', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id, 'key', shift_key, 'date', shift_date, 'time', shift_time,
        'box', box, 'klass', klass, 'originalCoach', original_coach,
        'status', status, 'claimedBy', claimed_by, 'createdBy', created_by)
        order by shift_date, shift_time)
      from requests where board_id = b_id and status <> 'cancelled'
    ), '[]'::jsonb)
  ) into out;
  return out;
end $$;

-- A coach asks for one of their own shifts to be covered.
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
  on conflict (board_id, shift_key) do nothing
  returning id into r_id;

  if r_id is null then
    return jsonb_build_object('ok', false, 'error', 'already_requested');
  end if;
  return jsonb_build_object('ok', true, 'id', r_id);
end $$;

-- THE important one. A single conditional UPDATE decides the winner:
-- Postgres serialises the row, so the second caller matches zero rows.
create or replace function claim_cover(p_token text, p_request uuid, p_coach text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b_id uuid; updated int; holder text; clash int;
begin
  b_id := board_id_for(p_token);
  if b_id is null then return jsonb_build_object('ok', false, 'error', 'unknown_board'); end if;
  if coalesce(trim(p_coach), '') = '' then return jsonb_build_object('ok', false, 'error', 'no_name'); end if;

  -- already teaching elsewhere at that moment?
  select count(*) into clash
  from requests r
  join shifts s
    on s.board_id = r.board_id
   and s.shift_date = r.shift_date
   and s.shift_time = r.shift_time
   and s.box <> r.box
  where r.id = p_request and r.board_id = b_id and s.coach = p_coach;

  update requests
     set status = 'claimed', claimed_by = p_coach, claimed_at = now()
   where id = p_request and board_id = b_id and status = 'open';
  get diagnostics updated = row_count;

  if updated = 0 then
    select claimed_by into holder from requests where id = p_request and board_id = b_id;
    return jsonb_build_object('ok', false, 'error', 'taken', 'takenBy', holder);
  end if;
  return jsonb_build_object('ok', true, 'clash', clash > 0);
end $$;

-- Undo your own claim (only your own, and only before the admin is asked).
create or replace function release_cover(p_token text, p_request uuid, p_coach text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b_id uuid; updated int;
begin
  b_id := board_id_for(p_token);
  if b_id is null then return jsonb_build_object('ok', false, 'error', 'unknown_board'); end if;
  update requests
     set status = 'open', claimed_by = null, claimed_at = null
   where id = p_request and board_id = b_id and status = 'claimed' and claimed_by = p_coach;
  get diagnostics updated = row_count;
  if updated = 0 then return jsonb_build_object('ok', false, 'error', 'not_yours'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- Admin side: replace the schedule for a board.
create or replace function push_shifts(p_admin text, p_shifts jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b_id uuid; n int;
begin
  select id into b_id from boards where admin_token = p_admin;
  if b_id is null then return jsonb_build_object('ok', false, 'error', 'unknown_admin'); end if;

  insert into shifts (board_id, shift_key, shift_date, shift_time, box, klass, coach)
  select b_id,
         x->>'key', (x->>'date')::date, x->>'time',
         x->>'box', x->>'klass', x->>'coach'
    from jsonb_array_elements(p_shifts) as x
  on conflict (board_id, shift_key) do update
    set coach = excluded.coach, klass = excluded.klass;
  get diagnostics n = row_count;

  -- anything the admin asked for that the schedule now agrees with is confirmed
  update requests r
     set status = case when s.coach = r.claimed_by then 'verified' else 'mismatch' end,
         checked_coach = s.coach, checked_at = now()
    from shifts s
   where s.board_id = r.board_id and s.shift_key = r.shift_key
     and r.board_id = b_id and r.claimed_by is not null
     and r.status in ('sent','mismatch','verified');

  return jsonb_build_object('ok', true, 'written', n);
end $$;

create or replace function mark_sent(p_admin text, p_request uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b_id uuid; updated int;
begin
  select id into b_id from boards where admin_token = p_admin;
  if b_id is null then return jsonb_build_object('ok', false, 'error', 'unknown_admin'); end if;
  update requests set status = 'sent', sent_at = now()
   where id = p_request and board_id = b_id and status = 'claimed';
  get diagnostics updated = row_count;
  return jsonb_build_object('ok', updated > 0);
end $$;

-- ------------------------------------------------------------- grants
revoke all on function board_state(text)                from public;
revoke all on function raise_cover(text, text, text)    from public;
revoke all on function claim_cover(text, uuid, text)    from public;
revoke all on function release_cover(text, uuid, text)  from public;
revoke all on function push_shifts(text, jsonb)         from public;
revoke all on function mark_sent(text, uuid)            from public;

grant execute on function board_state(text)               to anon, authenticated;
grant execute on function raise_cover(text, text, text)   to anon, authenticated;
grant execute on function claim_cover(text, uuid, text)   to anon, authenticated;
grant execute on function release_cover(text, uuid, text) to anon, authenticated;
grant execute on function push_shifts(text, jsonb)        to anon, authenticated;
grant execute on function mark_sent(text, uuid)           to anon, authenticated;

-- ------------------------------------------------- create your board
-- Runs once; prints the two tokens. Keep admin_token to yourself.
insert into boards (name, share_token, admin_token)
select 'Coach Covers', encode(gen_random_bytes(12), 'hex'), encode(gen_random_bytes(18), 'hex')
where not exists (select 1 from boards);

select name,
       share_token as "SHARE TOKEN  (goes in the coaches' link)",
       admin_token as "ADMIN TOKEN  (keep private)"
from boards;
