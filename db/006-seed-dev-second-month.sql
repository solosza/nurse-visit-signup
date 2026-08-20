-- 006-seed-dev-second-month.sql
--
-- Adds a September 2026 week to visits_dev so the multi-month navigation can
-- actually be exercised. With only August present both arrows sit disabled and
-- the feature is untestable -- a green test on a one-month table would prove
-- nothing about the thing it claims to prove.
--
-- This doubles as the evidence for the design claim: adding a month to the data
-- is the ONLY step needed to get a month in the UI. No code change, no redeploy.
-- If the September tab does not appear after running this, the claim is false.
--
-- DEV ONLY. Never run against public.visits -- the real schedule is authored by
-- whoever runs the service, not invented here.
--
-- Safe to re-run: seeds nothing if September rows already exist.

insert into public.visits_dev
      (id, visit_date, section, sort_order, time_label, patient_name, location, task, claimed_by, claimed_at)
select gen_random_uuid(),
       -- shift the first five August days forward one month, preserving weekday
       -- shape closely enough for a realistic-looking week
       (v.visit_date + interval '31 days')::date,
       v.section,
       v.sort_order,
       v.time_label,
       v.patient_name,
       v.location,
       v.task,
       null,
       null
from   public.visits_dev v
where  v.visit_date between date '2026-08-01' and date '2026-08-05'
  and  not exists (
         select 1 from public.visits_dev
         where visit_date >= date '2026-09-01' and visit_date < date '2026-10-01'
       );

-- ===========================================================================
-- Verification
-- ===========================================================================
select check_name, detail from (
  select 'months now present in dev' as check_name,
         string_agg(distinct to_char(visit_date, 'YYYY-MM'), ', ' order by to_char(visit_date, 'YYYY-MM')) as detail
  from public.visits_dev
  union all
  select 'september rows', count(*)::text
  from public.visits_dev
  where visit_date >= date '2026-09-01' and visit_date < date '2026-10-01'
  union all
  select 'september all unclaimed',
         case when not exists (
                select 1 from public.visits_dev
                where visit_date >= date '2026-09-01' and claimed_by is not null)
         then 'PASS' else 'FAIL' end
  union all
  select 'prod still single-month and 341 rows',
         case when (select count(*) from public.visits) = 341
               and (select count(distinct to_char(visit_date,'YYYY-MM')) from public.visits) = 1
         then 'PASS' else 'FAIL' end
) t order by check_name;
