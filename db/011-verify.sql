-- 011-verify.sql -- run this after 011-recurring-schedule.sql and READ it.
--
-- Asserts (against the catalog / pg_proc source, not this file's text):
--   * the three propagation functions exist,
--   * edit + delete bodies contain the claimed_by IS NULL guard -- a nurse's
--     sign-up can never be rewritten or removed by propagation,
--   * anon has NO privilege on either template table.
-- Every row must read PASS.

select check_name, detail from (

  select 'add_template_slot exists' as check_name,
         case when exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
               where n.nspname='public' and p.proname='add_template_slot')
              then 'PASS' else 'FAIL -- function missing' end as detail
  union all
  select 'edit_template_slot exists',
         case when exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
               where n.nspname='public' and p.proname='edit_template_slot')
              then 'PASS' else 'FAIL -- function missing' end
  union all
  select 'delete_template_slot exists',
         case when exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
               where n.nspname='public' and p.proname='delete_template_slot')
              then 'PASS' else 'FAIL -- function missing' end
  union all
  select 'CLAIMS SAFE: edit body guards on claimed_by is null',
         case when exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
               where n.nspname='public' and p.proname='edit_template_slot'
                 and lower(p.prosrc) like '%claimed_by is null%')
              then 'PASS' else 'FAIL -- edit is missing the claimed_by guard' end
  union all
  select 'CLAIMS SAFE: delete body guards on claimed_by is null',
         case when exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
               where n.nspname='public' and p.proname='delete_template_slot'
                 and lower(p.prosrc) like '%claimed_by is null%')
              then 'PASS' else 'FAIL -- delete is missing the claimed_by guard' end
  union all
  select 'anon has NO privilege on visit_template_dev',
         case when not exists (select 1 from information_schema.role_table_grants
               where table_schema='public' and table_name='visit_template_dev' and grantee='anon')
              then 'PASS' else 'FAIL -- anon can reach the dev template' end
  union all
  select 'anon has NO privilege on visit_template',
         case when not exists (select 1 from information_schema.role_table_grants
               where table_schema='public' and table_name='visit_template' and grantee='anon')
              then 'PASS' else 'FAIL -- anon can reach the live template' end

) checks order by detail desc, check_name;
