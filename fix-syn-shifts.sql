-- Stale rows from the very first schedule push (keyed "syn-…" by date/time/box,
-- before classes were keyed by their Arbox id). They duplicate real classes in
-- the day view. Move any request that points at one onto the real class, then
-- drop them. Safe to run more than once.
update requests r
   set shift_key = s.shift_key
  from shifts s
 where r.shift_key like 'syn-%'
   and s.board_id = r.board_id and s.shift_key not like 'syn-%'
   and s.shift_date = r.shift_date and left(s.shift_time,5) = left(r.shift_time,5)
   and s.box = r.box and coalesce(s.coach,'') = coalesce(r.original_coach,'')
   and not exists (select 1 from requests q where q.board_id = r.board_id and q.shift_key = s.shift_key);
delete from shifts where shift_key like 'syn-%';
