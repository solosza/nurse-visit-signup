-- 008-unique-visit-slot-index.sql
--
-- Makes idempotency STRUCTURAL, not a check that can be forgotten. Task 009's
-- generate_visits() inserts the standing schedule into a target table with an
-- ON CONFLICT DO NOTHING guard; that guard is only a real guarantee if the
-- database enforces uniqueness on the slot key it conflicts against. This
-- migration creates that constraint. Without it, ON CONFLICT has nothing to
-- conflict on and a re-run would silently double every day's rows.
--
-- The slot key is (visit_date, sort_order): on any given day, sort_order 1..11
-- names the eleven distinct slots of the standing schedule, so a (date, slot)
-- pair identifies exactly one visit. A second row with the same pair is a
-- duplicate by definition.
--
-- MEASURED SAFE (verified 2026-08-19): public.visits holds 341 rows and 341
-- distinct (visit_date, sort_order) pairs -- zero duplicates -- with sort_order
-- ranging 1..11. The unique index can therefore be created over the existing
-- data without a uniqueness violation. See 001-create-dev-tables.sql for the
-- schema of both tables.
--
-- WARNING -- read this before running:
--   If CREATE UNIQUE INDEX FAILS with a uniqueness violation ("could not create
--   unique index ... is duplicated"), then duplicate (visit_date, sort_order)
--   slots ALREADY EXIST in that table. If that happens:
--     * Generation (task 009 / the live generate step) must NOT proceed -- the
--       data is not in the shape the generator assumes, and inserting more rows
--       would compound the problem.
--     * NEVER delete rows to force the index through. Deleting real visit rows to
--       satisfy a constraint destroys production data (live PHI) to hide a defect.
--       Stop, investigate which pairs are duplicated, and resolve the source of
--       the duplication first.
--
-- One index per target table. public.visits (LIVE) gets visits_date_slot_uidx;
-- public.visits_dev (dev) gets visits_dev_date_slot_uidx. Both are named
-- explicitly so pg_indexes can assert each one exists.
--
-- Safe to re-run: both indexes are guarded by IF NOT EXISTS. This migration adds
-- only indexes -- it issues no INSERT, UPDATE or DELETE against either table, so
-- it can never change a single visit row. This repo is public: no patient or
-- nurse name appears in this file; only column and table names do.

begin;

-- ---------------------------------------------------------------------------
-- 1. Unique index on the LIVE table
-- ---------------------------------------------------------------------------
create unique index if not exists visits_date_slot_uidx
  on public.visits (visit_date, sort_order);

-- ---------------------------------------------------------------------------
-- 2. Unique index on the DEV table (same shape, distinct name)
-- ---------------------------------------------------------------------------
create unique index if not exists visits_dev_date_slot_uidx
  on public.visits_dev (visit_date, sort_order);

commit;

-- ===========================================================================
-- Verification -- run this and read it. "Ran without error" is not proof the
-- constraint exists: IF NOT EXISTS makes a no-op look identical to a create.
-- Assert each index by name via pg_indexes, and report per-table row count and
-- distinct-pair count so any hidden mismatch (rows > distinct pairs, which the
-- index should have made impossible) is visible.
-- ===========================================================================
select check_name, detail from (

  select 'live unique index visits_date_slot_uidx exists' as check_name,
         case when exists (
                select 1 from pg_indexes
                where schemaname = 'public'
                  and tablename  = 'visits'
                  and indexname  = 'visits_date_slot_uidx')
              then 'PASS' else 'FAIL -- index not present on public.visits' end as detail

  union all
  select 'dev unique index visits_dev_date_slot_uidx exists',
         case when exists (
                select 1 from pg_indexes
                where schemaname = 'public'
                  and tablename  = 'visits_dev'
                  and indexname  = 'visits_dev_date_slot_uidx')
              then 'PASS' else 'FAIL -- index not present on public.visits_dev' end

  union all
  select 'live visits: rows = distinct (visit_date, sort_order) pairs',
         case when (select count(*) from public.visits)
                 = (select count(*) from (
                      select distinct visit_date, sort_order from public.visits) d)
              then 'PASS -- ' || (select count(*) from public.visits)::text || ' rows, no duplicate slots'
              else 'FAIL -- ' || (select count(*) from public.visits)::text
                   || ' rows but only '
                   || (select count(*) from (
                         select distinct visit_date, sort_order from public.visits) d)::text
                   || ' distinct slot pairs (duplicates exist)' end

  union all
  select 'dev visits_dev: rows = distinct (visit_date, sort_order) pairs',
         case when (select count(*) from public.visits_dev)
                 = (select count(*) from (
                      select distinct visit_date, sort_order from public.visits_dev) d)
              then 'PASS -- ' || (select count(*) from public.visits_dev)::text || ' rows, no duplicate slots'
              else 'FAIL -- ' || (select count(*) from public.visits_dev)::text
                   || ' rows but only '
                   || (select count(*) from (
                         select distinct visit_date, sort_order from public.visits_dev) d)::text
                   || ' distinct slot pairs (duplicates exist)' end

) checks order by detail desc, check_name;
