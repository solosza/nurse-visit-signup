-- 009-generate-visits-function.sql
--
-- The generator. Migrations 007/008 stored the standing schedule once
-- (public.visit_template) and made the slot key (visit_date, sort_order) unique.
-- This function projects that template onto any date range, into any allowed
-- target table, so "add the next month" becomes a single call instead of a
-- hand-copied block of rows.
--
-- Its single most important property is that it is ADDITIVE ONLY. All 341 live
-- August rows are claimed by real nurses; generation must be structurally
-- incapable of touching a sign-up. The body therefore contains NO update and NO
-- delete of any kind against any table -- it can only INSERT new open slots, and
-- even that insert is guarded by ON CONFLICT (visit_date, sort_order) DO NOTHING
-- so a re-run over an already-generated range simply inserts zero rows. This is
-- the core safety guarantee, not a nicety; the verification block at the end
-- asserts the absence of update/delete from the stored function source.
--
-- claimed_by and claimed_at are always inserted as NULL: a generated visit is an
-- OPEN slot waiting for a nurse to sign up. The function never invents a claim.
--
-- Safety rails on the inputs:
--   * to_date < from_date is rejected -- a reversed range is a typo, not a request.
--   * a span over 366 days is rejected -- guards a mistyped year turning one call
--     into a million rows.
--   * target_table is checked against an allowlist of EXACTLY 'visits' and
--     'visits_dev' BEFORE it is ever interpolated, and is then placed into the
--     dynamic statement only through format(...) with %I identifier quoting -- it
--     is never string-concatenated, so it cannot become a SQL-injection point.
--
-- This repo is public. No patient or nurse name appears in this FILE: the
-- schedule's human-readable fields (patient_name, location, task) are copied
-- from public.visit_template at run time, never typed here. See
-- 007-create-visit-template.sql for the template and 001-create-dev-tables.sql
-- for the schema of both target tables.
--
-- Safe to re-run: CREATE OR REPLACE re-defines the function idempotently, and the
-- function's own insert is idempotent via the unique slot index from 008.

begin;

-- ---------------------------------------------------------------------------
-- generate_visits(from_date, to_date, target_table)
--
-- Expands public.visit_template across every date in the inclusive range
-- [from_date, to_date], keeping a template row for a given day only when:
--   * its weekday matches -- weekday IS NULL means "every day"; otherwise the
--     row applies only on dates whose EXTRACT(DOW ...) equals weekday
--     (0=Sunday .. 6=Saturday), and
--   * the day falls inside the row's active window -- active_from <= day and
--     (active_to IS NULL OR day <= active_to).
--
-- Returns the number of rows ACTUALLY inserted (ON CONFLICT skips are not
-- counted), so the caller can see at a glance whether a range was new or a
-- no-op re-run.
-- ---------------------------------------------------------------------------
create or replace function public.generate_visits(
  from_date    date,
  to_date      date,
  target_table text default 'visits'
) returns integer
language plpgsql
as $fn$
declare
  inserted_count integer;
begin
  -- Reversed range: a to_date before from_date is a typo, never a real request.
  if to_date < from_date then
    raise exception
      'generate_visits: to_date % is before from_date %', to_date, from_date;
  end if;

  -- Range guard: cap the span at 366 days so a mistyped year cannot expand into
  -- a million rows. 366 allows a full leap year in a single call.
  if (to_date - from_date) > 366 then
    raise exception
      'generate_visits: range % .. % spans % days, which exceeds the 366-day limit',
      from_date, to_date, (to_date - from_date);
  end if;

  -- Allowlist the target BEFORE it can reach the dynamic statement. Exactly two
  -- tables are permitted; anything else is rejected here, so the identifier that
  -- format(%I) later quotes is always one of two known-safe literals.
  if target_table not in ('visits', 'visits_dev') then
    raise exception
      'generate_visits: target_table % is not allowed (must be ''visits'' or ''visits_dev'')',
      target_table;
  end if;

  -- Additive insert only. The target table name is the ONLY dynamic element and
  -- it reaches the statement solely through %I identifier quoting; the date
  -- bounds are passed as parameters via USING, never interpolated.
  execute format($q$
    insert into public.%I
          (visit_date, section, sort_order, time_label,
           patient_name, location, task, claimed_by, claimed_at)
    select d.day::date,
           t.section,
           t.sort_order,
           t.time_label,
           t.patient_name,
           t.location,
           t.task,
           null,                       -- claimed_by:  generated visit is OPEN
           null                        -- claimed_at:  no claim exists yet
    from   generate_series($1::timestamp, $2::timestamp, interval '1 day') as d(day)
    join   public.visit_template t
      on   (t.weekday is null
            or t.weekday = extract(dow from d.day)::smallint)
     and   t.active_from <= d.day::date
     and   (t.active_to is null or d.day::date <= t.active_to)
    on conflict (visit_date, sort_order) do nothing
  $q$, target_table)
  using from_date, to_date;

  get diagnostics inserted_count = row_count;
  return inserted_count;
end;
$fn$;

commit;

-- ===========================================================================
-- Verification -- run this and read it. "Created without error" is not proof the
-- function has the right shape or the additive-only guarantee. Each check reports
-- PASS or an explicit FAIL reason, asserted against the catalog and the stored
-- function source (pg_proc.prosrc), not against the text of this file.
-- ===========================================================================
select check_name, detail from (

  select 'function public.generate_visits(date, date, text) exists' as check_name,
         case when exists (
                select 1
                from   pg_proc p
                join   pg_namespace n on n.oid = p.pronamespace
                where  n.nspname = 'public'
                  and  p.proname = 'generate_visits'
                  and  pg_get_function_identity_arguments(p.oid)
                       = 'from_date date, to_date date, target_table text')
              then 'PASS'
              else 'FAIL -- function missing or has the wrong signature' end as detail

  union all
  select 'returns integer',
         case when exists (
                select 1
                from   pg_proc p
                join   pg_namespace n on n.oid = p.pronamespace
                where  n.nspname = 'public'
                  and  p.proname = 'generate_visits'
                  and  pg_catalog.format_type(p.prorettype, null) = 'integer')
              then 'PASS'
              else 'FAIL -- return type is not integer' end

  union all
  select 'ADDITIVE ONLY: function source contains no UPDATE',
         case when not exists (
                select 1
                from   pg_proc p
                join   pg_namespace n on n.oid = p.pronamespace
                where  n.nspname = 'public'
                  and  p.proname = 'generate_visits'
                  and  lower(p.prosrc) ~ '\mupdate\M')
              then 'PASS'
              else 'FAIL -- the function body contains an UPDATE statement' end

  union all
  select 'ADDITIVE ONLY: function source contains no DELETE',
         case when not exists (
                select 1
                from   pg_proc p
                join   pg_namespace n on n.oid = p.pronamespace
                where  n.nspname = 'public'
                  and  p.proname = 'generate_visits'
                  and  lower(p.prosrc) ~ '\mdelete\M')
              then 'PASS'
              else 'FAIL -- the function body contains a DELETE statement' end

  union all
  select 'idempotent: ON CONFLICT guard present in function source',
         case when exists (
                select 1
                from   pg_proc p
                join   pg_namespace n on n.oid = p.pronamespace
                where  n.nspname = 'public'
                  and  p.proname = 'generate_visits'
                  and  lower(p.prosrc) like '%on conflict%')
              then 'PASS'
              else 'FAIL -- no ON CONFLICT guard found in the function body' end

) checks order by detail desc, check_name;
