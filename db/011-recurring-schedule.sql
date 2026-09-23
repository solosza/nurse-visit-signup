-- 011-recurring-schedule.sql
--
-- Feature 4: the client edits ONE master daily schedule (visit_template, db/007)
-- and it flows to every day; feature 3's per-day edits remain as overrides.
-- generate_visits (db/009) already handles the additive "add a slot" path. This
-- file adds the two paths it deliberately omits -- editing and removing a standing
-- slot -- under the client's rule: "leave claimed days alone, change only open ones."
--
-- SAFETY: every UPDATE/DELETE against a day table is guarded by BOTH
--   visit_date >= p_from   (future only; history is never rewritten) AND
--   claimed_by IS NULL     (open only; a nurse's sign-up is never touched),
-- and only rewrites rows that STILL equal the OLD template values (IS NOT DISTINCT
-- FROM), so a per-day tweak is preserved. Verified in db/011-verify.sql.
--
-- DEV ISOLATION: visit_template is one shared table, so this mirrors the
-- visits/visits_dev split with visit_template_dev. Functions derive both the
-- template and the day table from a single target_table arg ('visits' ->
-- visit_template ; 'visits_dev' -> visit_template_dev), allowlisted before use and
-- only interpolated via format(%I). This repo is public: no names in this FILE.
--
-- Safe to re-run: IF NOT EXISTS / NOT EXISTS guards, CREATE OR REPLACE, idempotent
-- grants, drop-then-create policies.

begin;

-- 1. Dev template table (mirrors visits/visits_dev) + seed from the shared one.
create table if not exists public.visit_template_dev (
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

insert into public.visit_template_dev
      (id, weekday, section, sort_order, time_label, patient_name, location, task, active_from, active_to)
select gen_random_uuid(), weekday, section, sort_order, time_label, patient_name, location, task, active_from, active_to
from   public.visit_template
where  not exists (select 1 from public.visit_template_dev);

-- 2. add_template_slot -- additive: insert the template row, stamp the slot onto
--    every matching day in range (ON CONFLICT DO NOTHING never touches a claim).
create or replace function public.add_template_slot(
  target_table text, p_section text, p_order integer, p_time text,
  p_patient text default null, p_location text default null, p_task text default null,
  p_weekday smallint default null, p_from date default current_date,
  p_to date default (current_date + 90)
) returns json language plpgsql as $fn$
declare tmpl text; new_id uuid; added_count integer;
begin
  if target_table = 'visits' then tmpl := 'visit_template';
  elsif target_table = 'visits_dev' then tmpl := 'visit_template_dev';
  else raise exception 'add_template_slot: target_table % is not allowed', target_table; end if;
  if p_to < p_from then raise exception 'add_template_slot: p_to before p_from'; end if;
  if (p_to - p_from) > 366 then raise exception 'add_template_slot: range exceeds 366 days'; end if;

  execute format('insert into public.%I (weekday, section, sort_order, time_label, patient_name, location, task, active_from, active_to)
                    values ($1,$2,$3,$4,$5,$6,$7,$8,null) returning id', tmpl)
    into new_id using p_weekday, p_section, p_order, p_time, p_patient, p_location, p_task, p_from;

  execute format($q$
    insert into public.%I (visit_date, section, sort_order, time_label, patient_name, location, task, claimed_by, claimed_at)
    select d.day::date, $2, $3, $4, $5, $6, $7, null, null
    from   generate_series($8::timestamp, $9::timestamp, interval '1 day') as d(day)
    where  ($1 is null or $1 = extract(dow from d.day)::smallint)
    on conflict (visit_date, sort_order) do nothing
  $q$, target_table)
    using p_weekday, p_section, p_order, p_time, p_patient, p_location, p_task, p_from, p_to;
  get diagnostics added_count = row_count;
  return json_build_object('template_id', new_id, 'days_added', added_count);
end; $fn$;

-- 3. edit_template_slot -- rewrite OPEN future matching days, keep+report claimed,
--    then update the template row. Preserves per-day tweaks (match-old chain).
create or replace function public.edit_template_slot(
  target_table text, p_id uuid, p_section text, p_order integer, p_time text,
  p_patient text default null, p_location text default null, p_task text default null,
  p_from date default current_date
) returns json language plpgsql as $fn$
declare
  tmpl text; o_section text; o_order integer; o_time text;
  o_patient text; o_location text; o_task text;
  updated_count integer; claimed_dates date[];
begin
  if target_table = 'visits' then tmpl := 'visit_template';
  elsif target_table = 'visits_dev' then tmpl := 'visit_template_dev';
  else raise exception 'edit_template_slot: target_table % is not allowed', target_table; end if;

  execute format('select section, sort_order, time_label, patient_name, location, task from public.%I where id = $1', tmpl)
    into o_section, o_order, o_time, o_patient, o_location, o_task using p_id;
  -- EXECUTE ... INTO does NOT set FOUND (unlike plain SELECT INTO); test a NOT NULL
  -- column of the row instead. sort_order is NOT NULL, so o_order is null <=> no row.
  if o_order is null then raise exception 'edit_template_slot: template row % not found', p_id; end if;

  execute format($q$
    select coalesce(array_agg(visit_date order by visit_date), '{}') from public.%I
    where visit_date >= $1 and claimed_by is not null and sort_order = $2
      and section is not distinct from $3 and time_label is not distinct from $4
      and patient_name is not distinct from $5 and location is not distinct from $6
      and task is not distinct from $7
  $q$, target_table) into claimed_dates
    using p_from, o_order, o_section, o_time, o_patient, o_location, o_task;

  execute format($q$
    update public.%I set section=$8, sort_order=$9, time_label=$10,
           patient_name=$11, location=$12, task=$13
    where visit_date >= $1 and claimed_by is null and sort_order = $2
      and section is not distinct from $3 and time_label is not distinct from $4
      and patient_name is not distinct from $5 and location is not distinct from $6
      and task is not distinct from $7
  $q$, target_table)
    using p_from, o_order, o_section, o_time, o_patient, o_location, o_task,
          p_section, p_order, p_time, p_patient, p_location, p_task;
  get diagnostics updated_count = row_count;

  execute format('update public.%I set section=$2, sort_order=$3, time_label=$4, patient_name=$5, location=$6, task=$7 where id=$1', tmpl)
    using p_id, p_section, p_order, p_time, p_patient, p_location, p_task;

  return json_build_object('days_updated', updated_count,
    'claimed_skipped', coalesce(array_length(claimed_dates, 1), 0),
    'claimed_dates', to_json(claimed_dates));
end; $fn$;

-- 4. delete_template_slot -- delete OPEN future matching days, keep+report claimed,
--    then delete the template row.
create or replace function public.delete_template_slot(
  target_table text, p_id uuid, p_from date default current_date
) returns json language plpgsql as $fn$
declare
  tmpl text; o_section text; o_order integer; o_time text;
  o_patient text; o_location text; o_task text;
  removed_count integer; claimed_dates date[];
begin
  if target_table = 'visits' then tmpl := 'visit_template';
  elsif target_table = 'visits_dev' then tmpl := 'visit_template_dev';
  else raise exception 'delete_template_slot: target_table % is not allowed', target_table; end if;

  execute format('select section, sort_order, time_label, patient_name, location, task from public.%I where id = $1', tmpl)
    into o_section, o_order, o_time, o_patient, o_location, o_task using p_id;
  -- EXECUTE ... INTO does NOT set FOUND; test a NOT NULL column instead (see edit_template_slot).
  if o_order is null then raise exception 'delete_template_slot: template row % not found', p_id; end if;

  execute format($q$
    select coalesce(array_agg(visit_date order by visit_date), '{}') from public.%I
    where visit_date >= $1 and claimed_by is not null and sort_order = $2
      and section is not distinct from $3 and time_label is not distinct from $4
      and patient_name is not distinct from $5 and location is not distinct from $6
      and task is not distinct from $7
  $q$, target_table) into claimed_dates
    using p_from, o_order, o_section, o_time, o_patient, o_location, o_task;

  execute format($q$
    delete from public.%I
    where visit_date >= $1 and claimed_by is null and sort_order = $2
      and section is not distinct from $3 and time_label is not distinct from $4
      and patient_name is not distinct from $5 and location is not distinct from $6
      and task is not distinct from $7
  $q$, target_table)
    using p_from, o_order, o_section, o_time, o_patient, o_location, o_task;
  get diagnostics removed_count = row_count;

  execute format('delete from public.%I where id = $1', tmpl) using p_id;

  return json_build_object('days_removed', removed_count,
    'claimed_kept', coalesce(array_length(claimed_dates, 1), 0),
    'claimed_dates', to_json(claimed_dates));
end; $fn$;

-- 5. Execute grants -- authenticated only (functions default to EXECUTE by PUBLIC).
revoke execute on function public.add_template_slot(text,text,integer,text,text,text,text,smallint,date,date) from public;
revoke execute on function public.edit_template_slot(text,uuid,text,integer,text,text,text,text,date) from public;
revoke execute on function public.delete_template_slot(text,uuid,date) from public;
grant  execute on function public.add_template_slot(text,text,integer,text,text,text,text,smallint,date,date) to authenticated;
grant  execute on function public.edit_template_slot(text,uuid,text,integer,text,text,text,text,date) to authenticated;
grant  execute on function public.delete_template_slot(text,uuid,date) to authenticated;

commit;

-- 011a -- DEV template access (prove here first). authenticated r/w; anon nothing.
-- Supabase default privileges grant new tables to anon too, so revoke anon
-- explicitly (RLS already blocks it, but this matches db/002's belt-and-suspenders).
grant select, insert, update, delete on public.visit_template_dev to authenticated;
revoke all on public.visit_template_dev from anon;
alter table public.visit_template_dev enable row level security;
drop policy if exists "auth all visit_template_dev" on public.visit_template_dev;
create policy "auth all visit_template_dev" on public.visit_template_dev
  for all to authenticated using (true) with check (true);

-- 011-security -- LIVE template lockdown. Applied IMMEDIATELY (not deferred): db/007
-- created visit_template with RLS OFF, and Supabase's default privileges had granted
-- anon full DELETE/INSERT/UPDATE/SELECT on it -- i.e. anyone with the public key
-- could rewrite or wipe the standing schedule. This closes that hole. It is purely
-- protective and enables NO editing (the passcode account can only edit the LIVE
-- template once db/010b grants it write on visits; until then edit/delete propagation
-- fails at the visits write). anon is left untouched on visits (still SELECT-only).
revoke all on public.visit_template from anon;
alter table public.visit_template enable row level security;
drop policy if exists "auth all visit_template" on public.visit_template;
create policy "auth all visit_template" on public.visit_template
  for all to authenticated using (true) with check (true);
