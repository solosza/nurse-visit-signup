-- 010-auth-scope-edits.sql
--
-- Feature 3: editing visit details & times, plus adding and deleting visits.
--
-- THE MODEL
--
-- 002 closed the write hole by revoking UPDATE/INSERT/DELETE from BOTH anon and
-- authenticated, then re-granting only UPDATE (claimed_by, claimed_at) to both.
-- So today nobody can edit patient/time/task/location, and nobody can add or
-- remove a visit. That is correct for the public (anon) page.
--
-- This migration opens editing to the AUTHENTICATED role only -- i.e. someone who
-- has signed in with the shared passcode account. anon is left exactly as 002 set
-- it: claim/release only. The publishable key in the page source therefore still
-- cannot rewrite a patient name, move a time, or delete a visit -- the closed
-- vulnerability stays closed.
--
-- Two layers, both required for a write:
--   1. Column/table GRANTs  -> WHICH columns/operations a role may touch.
--   2. RLS policies         -> WHICH rows. The existing "update claims" policy is
--      `to public USING(true) WITH CHECK(true)`, which already lets authenticated
--      UPDATE any row; the column GRANT below is what unlocks the detail columns.
--      INSERT and DELETE have no policy today, so this adds authenticated-only ones.
--
-- Editable columns: visit_date, section, sort_order, time_label, patient_name,
-- location, task. (claimed_by/claimed_at stay claim-only, already granted in 002.)
--
-- Note the unique index from 008 on (visit_date, sort_order): an edit or insert
-- that collides raises 23505. The page catches it and shows a friendly message.
--
-- Safe to re-run (grants are idempotent; policies are dropped-then-created).
-- Run 010a against visits_dev first, verify, then run 010b against visits.

-- ===========================================================================
-- 010a -- visits_dev ONLY. Prove it here before touching the live table.
-- ===========================================================================
grant update (visit_date, section, sort_order, time_label, patient_name, location, task)
  on public.visits_dev to authenticated;
grant insert, delete on public.visits_dev to authenticated;

drop policy if exists "auth insert visits_dev" on public.visits_dev;
drop policy if exists "auth delete visits_dev" on public.visits_dev;
create policy "auth insert visits_dev" on public.visits_dev
  for insert to authenticated with check (true);
create policy "auth delete visits_dev" on public.visits_dev
  for delete to authenticated using (true);

-- ===========================================================================
-- 010b -- the live table. Uncomment and run once 010a is verified on dev.
-- ===========================================================================
-- grant update (visit_date, section, sort_order, time_label, patient_name, location, task)
--   on public.visits to authenticated;
-- grant insert, delete on public.visits to authenticated;
--
-- drop policy if exists "auth insert visits" on public.visits;
-- drop policy if exists "auth delete visits" on public.visits;
-- create policy "auth insert visits" on public.visits
--   for insert to authenticated with check (true);
-- create policy "auth delete visits" on public.visits
--   for delete to authenticated using (true);

-- ===========================================================================
-- Verification -- run and read it.
--   1. authenticated should now be UPDATE-able on the 7 detail columns + the 2
--      claim columns, and have INSERT/DELETE (table-level).
--   2. anon must STILL be limited to UPDATE (claimed_by, claimed_at) and have NO
--      INSERT/DELETE. If anon shows anything more, STOP -- the hole reopened.
-- ===========================================================================
select table_name, grantee, privilege_type,
       coalesce(string_agg(column_name, ', ' order by column_name), '(table-level)') as columns
from (
  select c.table_name, c.grantee, c.privilege_type, c.column_name
  from information_schema.column_privileges c
  where c.table_schema = 'public'
    and c.table_name in ('visits', 'visits_dev')
    and c.grantee in ('anon', 'authenticated')
    and c.privilege_type in ('UPDATE', 'INSERT', 'DELETE')
  union all
  select t.table_name, t.grantee, t.privilege_type, null
  from information_schema.role_table_grants t
  where t.table_schema = 'public'
    and t.table_name in ('visits', 'visits_dev')
    and t.grantee in ('anon', 'authenticated')
    and t.privilege_type in ('INSERT', 'DELETE')
) x
group by table_name, grantee, privilege_type
order by table_name, grantee, privilege_type;
