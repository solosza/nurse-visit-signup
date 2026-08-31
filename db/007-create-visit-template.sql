-- 007-create-visit-template.sql
--
-- Stores the standing daily schedule ONCE. Today the live visits table holds the
-- same 11 facts repeated across all 31 August days -- 341 rows encoding a single
-- day-signature. That makes a schedule change a 330-row edit and makes "add the
-- next month" a manual copy. This table holds those 11 facts one time; task 009's
-- generate_visits() projects them onto any date range, into any target table.
--
-- Written against the ACTUAL schema of public.visits (see 001-create-dev-tables.sql,
-- verified 2026-08-19): id, visit_date, section, sort_order, time_label,
-- patient_name, location, task, claimed_by, claimed_at.
--
-- The 11 rows are NOT typed by hand -- they are derived from the real August data
-- with DISTINCT ON (sort_order), so the template is exactly what production already
-- runs, not a re-invention that could silently drift from it. No patient or nurse
-- name is ever written into this FILE: the values are read from the database at run
-- time. This repo is public.
--
-- weekday is NULL for every row because today every day of the week is identical.
-- The column exists so a future "Sundays are different" change is one row, not a
-- schema migration. active_from = 2026-09-01: the template governs ongoing months
-- from September onward; the already-authored August rows are left exactly as they are.
--
-- One template table serves BOTH targets. Which table to generate INTO is a
-- parameter of generate_visits() (task 009), never a second template table.
--
-- Safe to re-run: create is guarded by IF NOT EXISTS, the seed by NOT EXISTS.
-- Touches public.visits ONLY with SELECT. Contains no UPDATE or DELETE against
-- public.visits or public.visits_dev.

begin;

-- ---------------------------------------------------------------------------
-- 1. Structure
--
-- weekday smallint: NULL = every day; otherwise 0=Sunday .. 6=Saturday (matching
--   PostgreSQL's EXTRACT(DOW ...)), so the generator can filter by weekday later
--   with no translation.
-- active_from / active_to: the window in which a template row is in force.
--   active_to NULL = open-ended. This lets the schedule change over time without
--   deleting history.
-- ---------------------------------------------------------------------------
create table if not exists public.visit_template (
  id           uuid primary key default gen_random_uuid(),
  weekday      smallint,
  section      text    not null,
  sort_order   integer not null,
  time_label   text    not null,
  patient_name text,
  location     text,
  task         text,
  active_from  date    not null,
  active_to    date
);

-- ---------------------------------------------------------------------------
-- 2. Seed -- one row per slot, taken from the real schedule
--
-- DISTINCT ON (sort_order) with ORDER BY sort_order, visit_date keeps the first
-- (earliest-dated) August row for each of the 11 slots -- the canonical shape of
-- the standing day. All 31 August days are identical today, so which day is picked
-- does not matter; DISTINCT ON just guarantees exactly one row per slot.
--
-- The NOT EXISTS guard makes the whole seed a no-op once the table has any row, so
-- re-running the migration -- on dev, then on live -- never duplicates.
-- ---------------------------------------------------------------------------
insert into public.visit_template
      (id, weekday, section, sort_order, time_label, patient_name, location, task, active_from, active_to)
select distinct on (v.sort_order)
       gen_random_uuid(),
       null::smallint,          -- every day is identical today
       v.section,
       v.sort_order,
       v.time_label,
       v.patient_name,
       v.location,
       v.task,
       date '2026-09-01',       -- template governs ongoing months from September
       null::date               -- open-ended
from   public.visits v
where  v.visit_date between date '2026-08-01' and date '2026-08-31'
  and  not exists (select 1 from public.visit_template)
order by v.sort_order, v.visit_date;

commit;

-- ===========================================================================
-- Verification -- run this and read it. A migration that "ran without error" is
-- not the same as one that produced the standing schedule correctly.
-- Returns check_name / detail rows; PASS/FAIL cases are spelled out in detail.
-- ===========================================================================
select check_name, detail from (

  select 'template table exists' as check_name,
         case when to_regclass('public.visit_template') is not null
              then 'PASS' else 'FAIL -- table was not created' end as detail

  union all
  select 'exactly 11 rows',
         case when (select count(*) from public.visit_template) = 11
              then 'PASS'
              else 'FAIL -- got ' || (select count(*) from public.visit_template)::text end

  union all
  select '11 distinct sort_order values 1..11',
         case when (select count(distinct sort_order) from public.visit_template) = 11
               and (select min(sort_order) from public.visit_template) = 1
               and (select max(sort_order) from public.visit_template) = 11
              then 'PASS' else 'FAIL -- sort_order is not the contiguous set 1..11' end

  union all
  select 'no row missing section, time_label or task',
         case when not exists (
                select 1 from public.visit_template
                where section is null or time_label is null or task is null)
              then 'PASS' else 'FAIL -- a required schedule field is null' end

  union all
  select 'weekday null for every row (every day identical today)',
         case when not exists (select 1 from public.visit_template where weekday is not null)
              then 'PASS' else 'FAIL -- a weekday was set unexpectedly' end

  union all
  select 'active_from is 2026-09-01 for every row',
         case when not exists (select 1 from public.visit_template where active_from <> date '2026-09-01')
              then 'PASS' else 'FAIL -- a row has the wrong active_from' end

  union all
  select 'prod visits row count unchanged (341)',
         case when (select count(*) from public.visits) = 341
              then 'PASS' else 'FAIL -- this migration must never write to visits' end

) checks order by detail desc, check_name;
