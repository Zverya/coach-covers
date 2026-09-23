-- Migration: per-box admins, no approval gate.
-- Each box gets its own admin link that sees ONLY that box's swaps, confirms the
-- Arbox update was made, and the nightly scan verifies it. Paste into Supabase
-- SQL Editor and Run. Safe to run more than once.

-- ---- one admin token per box ----
create table if not exists box_admins (
  id          uuid primary key default gen_random_uuid(),
  board_id    uuid not null references boards(id) on delete cascade,
  box_name    text not null,
  admin_token text not null unique,
  created_at  timestamptz not null default now(),
  unique (board_id, box_name)
);
alter table box_admins enable row level security;
revoke all on box_admins from anon, authenticated;

-- create a token for every box currently on the board that doesn't have one
insert into box_admins (board_id, box_name, admin_token)
select b.id, s.box, encode(gen_random_bytes(12), 'hex')
from boards b
join (select distinct board_id, box from shifts where box is not null and box <> '') s
  on s.board_id = b.id
on conflict (board_id, box_name) do nothing;

-- ---- resolvers ----
-- board_role now also recognises a per-box admin token (role 'box_admin').
create or replace function board_role(p_token text, out b_id uuid, out role text)
language plpgsql stable security definer set search_path = public as $$
begin
  select id, 'admin' into b_id, role from boards where approver_token = p_token;
  if b_id is not null then return; end if;
  select board_id, 'box_admin' into b_id, role from box_admins where admin_token = p_token;
  if b_id is not null then return; end if;
  select id, 'coach' into b_id, role from boards where share_token = p_token;
end $$;

-- which box a box-admin token governs (null for other tokens)
create or replace function box_for_admin(p_token text)
returns text language sql stable security definer set search_path = public as $$
  select box_name from box_admins where admin_token = p_token;
$$;

-- ---- board_state: box admins see only their box ----
create or replace function board_state(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare b_id uuid; r text; abox text; out jsonb;
begin
  select br.b_id, br.role into b_id, r from board_role(p_token) br;
  if b_id is null then
    return jsonb_build_object('ok', false, 'error', 'unknown_board');
  end if;
  if r = 'box_admin' then abox := box_for_admin(p_token); end if;
  select jsonb_build_object(
    'ok', true,
    'role', r,
    'adminBox', abox,
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
        'status', status, 'claimedBy', claimed_by, 'createdBy', created_by,
        'checkedCoach', checked_coach)
        order by shift_date, shift_time)
      from requests
      where board_id = b_id and status <> 'cancelled'
        and (abox is null or box = abox)
    ), '[]'::jsonb)
  ) into out;
  return out;
end $$;

-- ---- confirm the Arbox update was made (admin or the box's admin) ----
create or replace function confirm_updated(p_token text, p_request uuid, p_undo boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b_id uuid; r text; abox text; updated int;
begin
  select br.b_id, br.role into b_id, r from board_role(p_token) br;
  if b_id is null or r not in ('admin','box_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_admin');
  end if;
  if r = 'box_admin' then abox := box_for_admin(p_token); end if;

  if p_undo then
    update requests set status = 'claimed', approved_at = null
     where id = p_request and board_id = b_id and status in ('approved','mismatch')
       and (abox is null or box = abox);
  else
    update requests set status = 'approved', approved_at = now()
     where id = p_request and board_id = b_id and status in ('claimed','mismatch')
       and (abox is null or box = abox);
  end if;
  get diagnostics updated = row_count;
  return jsonb_build_object('ok', updated > 0);
end $$;

-- ---- nightly scan: verify against the freshly-pushed schedule ----
-- Auto-verifies any swap Arbox now reflects; flags a mismatch only when the admin
-- marked it done but Arbox still shows the original coach; leaves not-yet-done
-- (claimed) swaps alone.
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
           when s.coach = r.claimed_by then 'verified'
           when r.status in ('approved','mismatch') then 'mismatch'
           else r.status
         end,
         checked_coach = s.coach, checked_at = now()
    from shifts s
   where s.board_id = r.board_id and s.shift_key = r.shift_key
     and r.board_id = b_id and r.claimed_by is not null
     and r.status in ('claimed','approved','mismatch','verified');

  return jsonb_build_object('ok', true, 'written', n);
end $$;

revoke all on function board_role(text)                    from public;
revoke all on function box_for_admin(text)                 from public;
revoke all on function confirm_updated(text,uuid,boolean)  from public;
grant execute on function box_for_admin(text)                to anon, authenticated;
grant execute on function confirm_updated(text,uuid,boolean) to anon, authenticated;

-- ---- the per-box admin links to hand out ----
select box_name as "BOX", admin_token as "ADMIN LINK token"
from box_admins
where board_id = (select id from boards limit 1)
order by box_name;
