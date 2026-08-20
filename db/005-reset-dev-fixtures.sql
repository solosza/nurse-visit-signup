-- 005-reset-dev-fixtures.sql
--
-- Resets visits_dev to a clean, presentable fixture state. Run it whenever dev
-- has accumulated test debris -- after a bug repro, a demo, or a run of manual
-- clicking.
--
-- Why this exists as a script rather than a one-off fix: dev data drifts by
-- design. That is what it is for. A table you can restore in one command is a
-- table people will actually experiment in, including destructively. The first
-- run of this was needed because reproducing the write vulnerability left a visit
-- whose patient name read "HACKED" -- fine for a test, alarming for anyone shown
-- the dev URL as a preview.
--
-- Touches public.visits ONLY with SELECT, and only to re-derive the anonymised
-- values. Never writes to it.
--
-- Safe to re-run. Idempotent.

begin;

-- ---------------------------------------------------------------------------
-- 1. Restore the non-claim columns from prod, re-anonymised.
--
-- dev was seeded 1:1 from prod, so (visit_date, sort_order) identifies the same
-- visit in both tables -- the ids deliberately differ. patient_name is re-derived
-- through the same dense_rank mapping used at seed time, so "Patient A" stays
-- "Patient A" across resets rather than shuffling.
-- ---------------------------------------------------------------------------
with anon_map as (
  select visit_date,
         sort_order,
         section,
         time_label,
         location,
         task,
         case when patient_name is null then null
              else 'Patient ' || chr(64 + (dense_rank() over (order by patient_name))::int)
         end as anon_name
  from public.visits
)
update public.visits_dev d
set    patient_name = m.anon_name,
       task         = m.task,
       location     = m.location,
       section      = m.section,
       time_label   = m.time_label
from   anon_map m
where  d.visit_date = m.visit_date
  and  d.sort_order = m.sort_order;

-- ---------------------------------------------------------------------------
-- 2. Reset claims to a known fixture: mostly free, a handful taken.
--
-- Both directions have to be exercisable. All-free leaves nothing to release;
-- all-taken leaves nothing to claim. Five taken is enough for either.
-- ---------------------------------------------------------------------------
update public.visits_dev set claimed_by = null, claimed_at = null;

update public.visits_dev
set    claimed_by = 'Test Nurse A',
       claimed_at = now()
where  id in (select id from public.visits_dev order by visit_date, sort_order limit 5);

commit;

-- ===========================================================================
-- Verification
-- ===========================================================================
select check_name, result from (
  select 'no test debris in patient_name' as check_name,
         case when not exists (
                select 1 from public.visits_dev
                where patient_name is not null and patient_name !~ '^Patient [A-Z]$')
         then 'PASS' else 'FAIL' end as result
  union all
  select 'no test debris in task',
         case when not exists (select 1 from public.visits_dev where task ilike '%hack%')
         then 'PASS' else 'FAIL' end
  union all
  select 'only fixture claimants',
         case when not exists (
                select 1 from public.visits_dev
                where claimed_by is not null and claimed_by <> 'Test Nurse A')
         then 'PASS' else 'FAIL' end
  union all
  select 'both claim paths testable',
         case when (select count(*) from public.visits_dev where claimed_by is null) > 0
               and (select count(*) from public.visits_dev where claimed_by is not null) > 0
         then 'PASS' else 'FAIL' end
  union all
  select 'no real patient names leaked',
         case when not exists (
                select 1 from public.visits_dev d
                where d.patient_name in (select patient_name from public.visits where patient_name is not null))
         then 'PASS' else 'FAIL' end
  union all
  select 'prod untouched (341 rows, 341 claimed)',
         case when (select count(*) from public.visits) = 341
               and (select count(*) from public.visits where claimed_by is not null) = 341
         then 'PASS' else 'FAIL' end
) t order by result desc, check_name;
