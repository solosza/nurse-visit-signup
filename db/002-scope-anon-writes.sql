-- 002-scope-anon-writes.sql
--
-- Closes the write hole found on 2026-08-19.
--
-- THE PROBLEM
--
-- The policy on visits is:
--     "update claims"  UPDATE  to public  USING (true)  WITH CHECK (true)
--
-- RLS decides which ROWS may be touched. It says nothing about which COLUMNS.
-- With a blanket UPDATE grant, anyone holding the publishable key -- which ships
-- in the page source -- can rewrite any column of any row: patient names, dates,
-- times, tasks. Not just claims. `WITH CHECK (true)` validates nothing on the way
-- in. The reason this has never happened is that the client only ever sends
-- claimed_by/claimed_at. The client is not a control; anyone can send their own
-- request and skip it entirely.
--
-- THE FIX
--
-- Postgres column-level privileges, which is the standard mechanism for this and
-- the one Supabase documents. Privileges and RLS are separate layers and a write
-- needs BOTH, so scoping the grant scopes the write no matter what policy says.
--
--     revoke update on <table> from anon, authenticated;
--     grant  update (claimed_by, claimed_at) on <table> to anon, authenticated;
--
-- The row policy is deliberately left alone. Narrowing WHICH ROWS may be claimed
-- requires knowing who is asking, which needs identity -- that is step 2/3 of
-- ROADMAP.md, not this migration.
--
-- IMPACT ON THE RUNNING APP: none. claim() and release() write exactly
-- claimed_by and claimed_at and nothing else.
--
-- Safe to re-run. Applies to visits_dev and visits.
-- Run 002a first, verify, then 002b.

-- ===========================================================================
-- 002a -- visits_dev ONLY. Prove it here before touching the live table.
-- ===========================================================================
revoke update, insert, delete on public.visits_dev from anon, authenticated;
grant  update (claimed_by, claimed_at) on public.visits_dev to anon, authenticated;

-- INSERT and DELETE are revoked above and have no policy either, so they are
-- blocked at both layers. That is intentional belt-and-braces: the schedule is
-- seeded by an operator, never by a page visitor.

-- ===========================================================================
-- 002b -- the live table. Uncomment and run once 002a is verified.
-- ===========================================================================
-- revoke update, insert, delete on public.visits from anon, authenticated;
-- grant  update (claimed_by, claimed_at) on public.visits to anon, authenticated;

-- ===========================================================================
-- Verification -- what anon and authenticated may actually write, per column.
-- Expect exactly two updatable columns per table: claimed_by, claimed_at.
-- ===========================================================================
select table_name,
       grantee,
       privilege_type,
       coalesce(string_agg(column_name, ', ' order by column_name), '(table-level)') as columns
from (
  select c.table_name, c.grantee, c.privilege_type, c.column_name
  from information_schema.column_privileges c
  where c.table_schema = 'public'
    and c.table_name in ('visits', 'visits_dev')
    and c.grantee in ('anon', 'authenticated')
    and c.privilege_type in ('UPDATE', 'INSERT', 'DELETE')
) x
group by table_name, grantee, privilege_type
order by table_name, grantee, privilege_type;
