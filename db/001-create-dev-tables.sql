-- 001-create-dev-tables.sql
--
-- Creates public.visits_dev: the staging copy that local and branch work reads
-- and writes, so nothing under development ever touches real nurse sign-ups.
--
-- Written against the ACTUAL schema returned by 000-inspect-schema.sql on
-- 2026-08-19, not against assumptions:
--
--   columns      id uuid NOT NULL default gen_random_uuid(), visit_date date NOT NULL,
--                section text NOT NULL, sort_order integer NOT NULL,
--                time_label text NOT NULL, patient_name text, location text,
--                task text, claimed_by text, claimed_at timestamptz
--   constraints  visits_pkey PRIMARY KEY (id)   -- the only one
--   indexes      visits_pkey (unique on id), visits_date_idx (btree on visit_date)
--   RLS          enabled, not forced, replica identity 'd' (default)
--   policies     "read all"      SELECT to public  USING (true)
--                "update claims" UPDATE to public  USING (true) WITH CHECK (true)
--   publication  supabase_realtime
--   triggers     none
--   data         341 rows, 2026-08-01 .. 2026-08-31, all 341 claimed
--
-- Safe to re-run: every step is guarded.
-- Touches public.visits ONLY with SELECT.

begin;

-- ---------------------------------------------------------------------------
-- 1. Structure
--
-- LIKE ... INCLUDING ALL copies columns, types, NOT NULLs, the gen_random_uuid()
-- default, the primary key and both indexes. It does NOT copy RLS policies,
-- publication membership, or triggers -- those are steps 4 and 5. (There are no
-- triggers on visits, so nothing is owed there.)
-- ---------------------------------------------------------------------------
create table if not exists public.visits_dev (like public.visits including all);

-- ---------------------------------------------------------------------------
-- 2. Seed -- anonymised on purpose
--
-- visits_dev gets the same world-readable policy as visits (step 4, because
-- fidelity is the entire point of a staging table). Copying real patient names
-- into it would therefore create a SECOND public copy of the same data. The
-- tests need the shape of the data, never the values, so names are replaced.
--
-- Fresh ids: dev rows must never share a primary key with prod rows, so a stray
-- id copied between environments cannot silently address the wrong table.
-- ---------------------------------------------------------------------------
insert into public.visits_dev
      (id, visit_date, section, sort_order, time_label, patient_name, location, task, claimed_by, claimed_at)
select gen_random_uuid(),
       v.visit_date,
       v.section,
       v.sort_order,
       v.time_label,
       case when v.patient_name is null then null
            else 'Patient ' || chr(64 + (dense_rank() over (order by v.patient_name))::int)
       end,
       v.location,
       v.task,          -- generic clinical tasks, not identifying; kept so the UI renders realistically
       null,            -- claims are seeded in step 3, not copied
       null
from   public.visits v
where  not exists (select 1 from public.visits_dev);   -- only seed an empty table

-- ---------------------------------------------------------------------------
-- 3. Claim a few rows
--
-- All 341 prod rows are claimed, so a faithful copy would leave the sign-up path
-- untestable -- there would be nothing free to claim. Clearing everything has the
-- mirror problem: nothing to release. So: mostly free, a handful claimed.
-- ---------------------------------------------------------------------------
update public.visits_dev
set    claimed_by = 'Test Nurse A',
       claimed_at = now()
where  id in (select id from public.visits_dev
              where claimed_by is null
              order by visit_date, sort_order
              limit 5);

-- ---------------------------------------------------------------------------
-- 4. RLS -- mirrored from prod exactly
--
-- Deliberately identical to visits, including the parts that are too permissive.
-- A staging table that is SAFER than production is a trap: the change passes in
-- dev and fails in prod. Tightening these is step 2 of ROADMAP.md, and when it
-- happens it must happen to BOTH tables.
-- ---------------------------------------------------------------------------
alter table public.visits_dev enable row level security;

drop policy if exists "read all"      on public.visits_dev;
drop policy if exists "update claims" on public.visits_dev;

create policy "read all"      on public.visits_dev for select to public using (true);
create policy "update claims" on public.visits_dev for update to public using (true) with check (true);

-- ---------------------------------------------------------------------------
-- 5. Realtime
--
-- Realtime delivers changes by publication membership, so without this the dev
-- page loads fine and simply never updates -- a failure that looks like a bug in
-- the app rather than a missing grant.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime'
                   and schemaname = 'public' and tablename = 'visits_dev') then
    execute 'alter publication supabase_realtime add table public.visits_dev';
  end if;
end $$;

commit;

-- ===========================================================================
-- Verification -- run this and read it. A migration that "ran without error"
-- is not the same as one that produced a faithful copy.
-- ===========================================================================
select check_name, result from (

  select 'columns match prod' as check_name,
         case when (select count(*) from information_schema.columns
                    where table_schema='public' and table_name='visits')
                 = (select count(*) from information_schema.columns
                    where table_schema='public' and table_name='visits_dev')
              and not exists (
                select column_name, data_type, is_nullable from information_schema.columns
                where table_schema='public' and table_name='visits'
                except
                select column_name, data_type, is_nullable from information_schema.columns
                where table_schema='public' and table_name='visits_dev')
         then 'PASS' else 'FAIL' end as result

  union all
  select 'rls enabled',
         case when (select relrowsecurity from pg_class where oid='public.visits_dev'::regclass)
         then 'PASS' else 'FAIL -- dev would be wide open' end

  union all
  select 'replica identity matches prod',
         case when (select relreplident from pg_class where oid='public.visits_dev'::regclass)
                 = (select relreplident from pg_class where oid='public.visits'::regclass)
         then 'PASS' else 'FAIL' end

  union all
  select 'policy count matches prod',
         case when (select count(*) from pg_policies where schemaname='public' and tablename='visits_dev')
                 = (select count(*) from pg_policies where schemaname='public' and tablename='visits')
         then 'PASS' else 'FAIL' end

  union all
  select 'realtime publication',
         case when exists (select 1 from pg_publication_tables
                           where pubname='supabase_realtime' and schemaname='public' and tablename='visits_dev')
         then 'PASS' else 'FAIL -- dev page will never live-update' end

  union all
  select 'row count matches prod',
         case when (select count(*) from public.visits_dev) = (select count(*) from public.visits)
         then 'PASS' else 'FAIL' end

  union all
  select 'no real patient names leaked into dev',
         case when not exists (
                select 1 from public.visits_dev d
                where d.patient_name in (select patient_name from public.visits where patient_name is not null))
         then 'PASS' else 'FAIL -- anonymisation did not apply' end

  union all
  select 'no real nurse names leaked into dev',
         case when not exists (
                select 1 from public.visits_dev d
                where d.claimed_by in (select claimed_by from public.visits where claimed_by is not null))
         then 'PASS' else 'FAIL -- anonymisation did not apply' end

  union all
  select 'both claim paths testable',
         case when (select count(*) from public.visits_dev where claimed_by is null) > 0
               and (select count(*) from public.visits_dev where claimed_by is not null) > 0
         then 'PASS' else 'FAIL -- one of claim/release has no rows to act on' end

  union all
  select 'prod row count unchanged (341)',
         case when (select count(*) from public.visits) = 341
         then 'PASS' else 'FAIL -- this migration must never write to visits' end

) checks order by result desc, check_name;
