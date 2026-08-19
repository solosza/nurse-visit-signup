-- 003-require-auth.sql
--
-- Closes the READ exposure (D5 in ROADMAP.md).
--
-- THE PROBLEM
--
-- The "read all" policy is `TO public USING (true)`. `public` in Postgres means
-- every role, including `anon` -- the role the publishable key in the page source
-- maps to. Measured 2026-08-19: an anonymous request returned all 341 rows,
-- carrying 4 patient first names, 6 care task descriptions, 10 nurse names and 3
-- locations. Anyone who opens View Source on the live site can reproduce it.
--
-- 002 scoped what anon may WRITE. This scopes what anon may READ, which is the
-- larger half of the exposure and the one that cannot be fixed in the client:
-- gating the HTML gates nothing, because the data is served by PostgREST and the
-- key is public.
--
-- THE FIX
--
-- Restrict both policies to the `authenticated` role and revoke anon's SELECT
-- grant. Two layers again: the policy stops anon rows, the revoke makes the
-- refusal explicit (42501) instead of a silently empty result. An empty result is
-- ambiguous -- it could mean "no data" -- and the page needs to tell "you are not
-- signed in" apart from "there is nothing scheduled".
--
-- Identity model: a single shared account whose password IS the passcode
-- (feature 6 of the roadmap). This is deliberately NOT per-nurse accounts:
--   * it closes the exposure now, without onboarding ten people first
--   * it matches what was actually asked for -- "a passcode to protect the link"
--   * per-nurse attribution stays exactly where it is today, a name in
--     localStorage, which is honest about what it is
-- The trade, stated plainly: one shared credential cannot be revoked per person
-- and cannot attribute a sign-up to a verified individual. Features 2, 4 and 8
-- (colour coding, my-schedule, timesheet) will want real accounts eventually.
-- This migration does not block that -- swapping the shared account for per-nurse
-- accounts later changes nothing here, because the policies key on the ROLE, not
-- on which user holds it.
--
-- !! OPERATIONAL WARNING !!
-- The moment 003b runs, every nurse without the passcode is locked out of the
-- live schedule. Distribute the passcode BEFORE running it.
--
-- Safe to re-run.

-- ===========================================================================
-- 003a -- visits_dev ONLY. Prove it here first.
-- ===========================================================================
alter policy "read all"      on public.visits_dev to authenticated;
alter policy "update claims" on public.visits_dev to authenticated;

revoke select on public.visits_dev from anon;
grant  select on public.visits_dev to authenticated;
grant  update (claimed_by, claimed_at) on public.visits_dev to authenticated;

-- ===========================================================================
-- 003b -- the LIVE table. Uncomment and run ONLY after the passcode has been
-- given to the nurses. This is the switch that locks out anyone without it.
-- ===========================================================================
-- alter policy "read all"      on public.visits to authenticated;
-- alter policy "update claims" on public.visits to authenticated;
--
-- revoke select on public.visits from anon;
-- grant  select on public.visits to authenticated;
-- grant  update (claimed_by, claimed_at) on public.visits to authenticated;

-- ===========================================================================
-- Verification -- which roles each policy applies to, and what anon retains.
-- Expect: every policy {authenticated}; anon holds no SELECT on a migrated table.
-- ===========================================================================
select check_name, detail from (

  select 'policy roles: ' || tablename || '.' || policyname as check_name,
         array_to_string(roles, ',') as detail
  from pg_policies
  where schemaname = 'public' and tablename in ('visits', 'visits_dev')

  union all

  select 'anon privileges on ' || table_name,
         coalesce(string_agg(distinct privilege_type, ', '), 'NONE')
  from information_schema.table_privileges
  where table_schema = 'public'
    and table_name in ('visits', 'visits_dev')
    and grantee = 'anon'
  group by table_name

  union all

  select 'authenticated privileges on ' || table_name,
         coalesce(string_agg(distinct privilege_type, ', '), 'NONE')
  from information_schema.table_privileges
  where table_schema = 'public'
    and table_name in ('visits', 'visits_dev')
    and grantee = 'authenticated'
  group by table_name

) t order by check_name;
