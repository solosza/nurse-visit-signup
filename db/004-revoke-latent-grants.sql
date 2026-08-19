-- 004-revoke-latent-grants.sql
--
-- Found while verifying 003: `anon` holds TRUNCATE, REFERENCES and TRIGGER on
-- both tables. These come from Supabase's default `grant all on all tables in
-- schema public to anon, authenticated` and nothing in this app has ever used
-- them.
--
-- How bad is it? Not currently exploitable. PostgREST exposes no endpoint that
-- issues TRUNCATE -- probed directly, it answers 501 Not Implemented -- so there
-- is no route from the publishable key to these privileges today. Worth stating
-- plainly rather than overselling it.
--
-- Worth revoking anyway, for two reasons:
--   1. TRUNCATE is not filtered by RLS. If any future path ever reaches it, row
--      policies provide no protection at all -- the whole schedule goes in one
--      statement, and there is no undo.
--   2. The grant exists for no reason. A privilege nothing uses is pure downside.
--
-- This is safe to run on the live table right now and does NOT need to wait for
-- the passcode rollout: the app has never issued TRUNCATE, REFERENCES or TRIGGER,
-- so revoking them cannot change its behaviour. Unlike 003b, running this locks
-- nobody out.
--
-- Safe to re-run.

revoke truncate, references, trigger on public.visits     from anon, authenticated;
revoke truncate, references, trigger on public.visits_dev from anon, authenticated;

-- ===========================================================================
-- Verification -- what anon and authenticated retain on each table.
-- Expect anon: SELECT + UPDATE on visits (until 003b), nothing on visits_dev.
-- Expect authenticated: SELECT + UPDATE on both. No TRUNCATE anywhere.
-- ===========================================================================
select table_name,
       grantee,
       string_agg(distinct privilege_type, ', ' order by privilege_type) as privileges
from information_schema.table_privileges
where table_schema = 'public'
  and table_name in ('visits', 'visits_dev')
  and grantee in ('anon', 'authenticated')
group by table_name, grantee
order by table_name, grantee;
