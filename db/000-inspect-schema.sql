-- 000-inspect-schema.sql
--
-- READ-ONLY. Changes nothing. Run this in the Supabase SQL editor and paste the
-- output back.
--
-- Why this exists: the dev table has to be a faithful copy of `visits` --- same
-- columns, same constraints, same RLS policies, same realtime setup. If the dev
-- table is more permissive than prod, a change can pass every test in dev and
-- then fail in prod, which is worse than having no staging at all. So the
-- migration that creates `visits_dev` is written against the real schema rather
-- than against assumptions read off the front-end code.
--
-- Everything is returned as one labelled text column so the Supabase editor
-- shows it in a single result set.

select info from (

  -- columns: names, types, nullability, defaults, identity
  select 'A_COLUMN     | ' || column_name
       || ' | type='       || data_type
       || ' | nullable='   || is_nullable
       || ' | default='    || coalesce(column_default, '-')
       || ' | identity='   || coalesce(is_identity, '-')
       || ' | generation=' || coalesce(identity_generation, '-') as info
  from information_schema.columns
  where table_schema = 'public' and table_name = 'visits'

  union all

  -- primary key, unique, check, foreign key
  select 'B_CONSTRAINT | ' || conname || ' | ' || pg_get_constraintdef(oid)
  from pg_constraint
  where conrelid = 'public.visits'::regclass

  union all

  select 'C_INDEX      | ' || indexname || ' | ' || indexdef
  from pg_indexes
  where schemaname = 'public' and tablename = 'visits'

  union all

  -- is RLS on, and what replica identity does realtime have to work with
  select 'D_TABLE      | rls_enabled=' || relrowsecurity::text
       || ' | rls_forced='            || relforcerowsecurity::text
       || ' | replica_identity='      || relreplident::text  -- pg "char" type: the cast is
                                                            -- required, or `text || "char"`
                                                            -- is ambiguous and errors 42725
  from pg_class
  where oid = 'public.visits'::regclass

  union all

  -- the policies that actually decide what the anon key may do
  select 'E_POLICY     | ' || policyname
       || ' | permissive=' || permissive
       || ' | cmd='        || cmd
       || ' | roles='      || array_to_string(roles, ',')
       || ' | using='      || coalesce(qual, '-')
       || ' | with_check=' || coalesce(with_check, '-')
  from pg_policies
  where schemaname = 'public' and tablename = 'visits'

  union all

  -- realtime works by publication membership; dev must be added too
  select 'F_PUBLICATION| ' || pubname
  from pg_publication_tables
  where schemaname = 'public' and tablename = 'visits'

  union all

  select 'G_TRIGGER    | ' || tgname || ' | ' || pg_get_triggerdef(oid)
  from pg_trigger
  where tgrelid = 'public.visits'::regclass and not tgisinternal

  union all

  -- shape of the data, so the seed and the month-label work can be sanity-checked
  select 'H_DATA       | rows=' || count(*)::text
       || ' | min_date='        || coalesce(min(visit_date)::text, '-')
       || ' | max_date='        || coalesce(max(visit_date)::text, '-')
       || ' | claimed='         || count(claimed_by)::text
  from public.visits

) t
order by info;
