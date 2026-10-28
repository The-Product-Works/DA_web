-- Tables the collection workflow writes to besides the raw tables.
-- Run once in the Supabase SQL editor, after scripts/raw_tables.sql.
-- The agent_logs columns are a proposal: agree the final format with the data-out track (day 2).

create schema if not exists ops;

create table if not exists ops.agent_logs (
    id            bigserial primary key,
    run_id        text,
    logged_at     timestamptz default now(),
    agent         text,          -- collection / cleaning / transformation / insights / orchestrator
    action        text,          -- e.g. load, data_contract, mismatch_check, run_complete
    source        text,
    target_table  text,
    status        text,          -- success / warning / failed
    rows_read     integer,
    rows_written  integer,
    duration_ms   integer,
    reason        text,
    details       jsonb
);

create table if not exists ops.data_contracts (
    id          bigserial primary key,
    run_id      text,
    source      text,            -- '_cross_source' for the mismatch report
    raw_table   text,
    contract    jsonb,
    profile     jsonb,           -- the column profile the contract was based on; later runs compare against it
    created_at  timestamptz default now()
);

-- If ops.data_contracts was created before the profile column existed:
alter table ops.data_contracts add column if not exists profile jsonb;
