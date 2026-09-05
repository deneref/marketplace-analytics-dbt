-- One-off Snowflake setup. Run in Snowsight as ACCOUNTADMIN (the trial user), top to bottom.
-- Then: generate a key pair locally (see README) and paste the public key into the ALTER USER below.

use role accountadmin;

-- 1. Compute + storage. auto_suspend=60 so trial credits don't burn while idle.
create warehouse if not exists dbt_wh
  warehouse_size = 'x-small' auto_suspend = 60 auto_resume = true initially_suspended = true;
create database if not exists marketplace;
create schema if not exists marketplace.raw;       -- as-is exports from the seller API (ingest/load_to_snowflake.py)
create schema if not exists marketplace.dbt_dev;   -- dbt, real data, your laptop
create schema if not exists marketplace.dbt_ci;    -- dbt, synthetic seeds, GitHub Actions

-- 2. Service user for dbt / loader / CI / Looker Studio. TYPE=SERVICE → no MFA; key-pair auth only.
create user if not exists dbt_svc
  type = service
  default_role = sysadmin
  default_warehouse = dbt_wh
  default_namespace = marketplace.dbt_dev
  comment = 'marketplace-analytics-dbt: dbt, ingest, CI, Looker Studio';
grant role sysadmin to user dbt_svc;

-- 3. Public key (the .pub file without BEGIN/END lines, as one string).
-- alter user dbt_svc set rsa_public_key = 'MIIBIjANBgkq...';

-- 4. SYSADMIN owns what it creates; make sure it owns these too if you created them as ACCOUNTADMIN.
grant ownership on warehouse dbt_wh to role sysadmin copy current grants;
grant ownership on database marketplace to role sysadmin copy current grants;
grant ownership on all schemas in database marketplace to role sysadmin copy current grants;

-- 5. Check: should return the fingerprint of the key you set.
-- desc user dbt_svc;
