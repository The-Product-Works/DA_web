-- Tables and helpers for the cleaning workflow. Run once in the Supabase SQL editor,
-- after scripts/raw_tables.sql and n8n/ops_tables.sql. Safe to run again.
--
--   clean.*     typed, cleaned tables: the hand-over to the data-out track (table contract below)
--   cleaning.*  work area: one working copy per source, rebuilt from raw on every run, plus helper functions
--   ops.cleaning_rules      every rule the agent proposed, with its risk, decision and rows affected
--   ops.cleaning_approvals  cleaning runs waiting for a person to approve risky rules
--   ops.quarantine          rows the cleaning removed whose content is not kept anywhere else in clean.*

create schema if not exists clean;
create schema if not exists cleaning;
create schema if not exists ops;

-- ---------- table contract (proposal: original Olist names and types) ----------

create table if not exists clean.orders (
    order_id                        text primary key,
    customer_id                     text,
    order_status                    text,
    order_purchase_timestamp        timestamp,
    order_approved_at               timestamp,
    order_delivered_carrier_date    timestamp,
    order_delivered_customer_date   timestamp,
    order_estimated_delivery_date   timestamp
);

create table if not exists clean.order_items (
    order_id                        text,
    order_item_id                   integer,
    product_id                      text,
    seller_id                       text,
    shipping_limit_date             timestamp,
    price                           numeric(12,2),
    freight_value                   numeric(12,2),
    primary key (order_id, order_item_id)
);

create table if not exists clean.customers (
    customer_id                     text primary key,
    customer_unique_id              text,
    customer_zip_code_prefix        text,
    customer_city                   text,
    customer_state                  text
);

create table if not exists clean.sellers (
    seller_id                       text primary key,
    seller_zip_code_prefix          text,
    seller_city                     text,
    seller_state                    text
);

create table if not exists clean.geolocation (
    geolocation_zip_code_prefix     text,
    geolocation_lat                 double precision,
    geolocation_lng                 double precision,
    geolocation_city                text,
    geolocation_state               text
);

create table if not exists clean.products (
    product_id                      text primary key,
    product_category_name           text,
    product_name_lenght             integer,
    product_description_lenght      integer,
    product_photos_qty              integer,
    product_weight_g                integer,
    product_length_cm               integer,
    product_height_cm               integer,
    product_width_cm                integer
);

create table if not exists clean.category_translation (
    product_category_name           text primary key,
    product_category_name_english   text
);

create table if not exists clean.payments (
    order_id                        text,
    payment_sequential              integer,
    payment_type                    text,
    payment_installments            integer,
    payment_value                   numeric(12,2),
    primary key (order_id, payment_sequential)
);

create table if not exists clean.reviews (
    review_id                       text,
    order_id                        text,
    review_score                    smallint,
    review_comment_title            text,
    review_comment_message          text,
    review_creation_date            timestamp,
    review_answer_timestamp         timestamp,
    primary key (review_id, order_id)
);

-- ---------- helper functions (used by the rules and the final typing step) ----------

-- A number written plainly (-12.5), else null. Never raises an error.
create or replace function cleaning.try_numeric(v text) returns numeric
language sql immutable as $$
    select case when btrim(v) ~ '^-?[0-9]+(\.[0-9]+)?$' then btrim(v)::numeric end
$$;

-- A whole number (3 or 3.0), else null
create or replace function cleaning.try_int(v text) returns integer
language sql immutable as $$
    select case when cleaning.try_numeric(v) = trunc(cleaning.try_numeric(v))
                 and abs(cleaning.try_numeric(v)) < 2147483647
                then cleaning.try_numeric(v)::integer end
$$;

create or replace function cleaning.ts_or_null(v text) returns timestamp
language plpgsql immutable as $$
begin
    return v::timestamp;
exception when others then
    return null;
end $$;

-- Only the target format YYYY-MM-DD [HH:MI[:SS]] counts as a timestamp. Anything else is null.
create or replace function cleaning.try_timestamp(v text) returns timestamp
language sql immutable as $$
    select case when btrim(v) ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}( [0-9]{2}:[0-9]{2}(:[0-9]{2})?)?$'
                then cleaning.ts_or_null(btrim(v)) end
$$;

-- to_timestamp() that returns null instead of raising an error on impossible dates (13/25/2017)
create or replace function cleaning.try_to_timestamp(v text, fmt text) returns timestamp
language plpgsql immutable as $$
declare
    result timestamp;
begin
    result := to_timestamp(btrim(v), fmt)::timestamp;
    -- to_timestamp quietly rolls 31/02 over into March; refuse that
    if to_char(result, fmt) <> btrim(v) and fmt not like '%"T"%' then
        return null;
    end if;
    return result;
exception when others then
    return null;
end $$;

-- Removes Portuguese accents without needing the unaccent extension
create or replace function cleaning.unaccent_pt(v text) returns text
language sql immutable as $$
    select translate(v, 'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ',
                        'aaaaaeeeeiiiiooooouuuucnAAAAAEEEEIIIIOOOOOUUUUCN')
$$;

-- Comparison form: lower case, no accents, single spaces, trimmed
create or replace function cleaning.norm(v text) returns text
language sql immutable as $$
    select lower(cleaning.unaccent_pt(btrim(regexp_replace(v, '\s+', ' ', 'g'))))
$$;

-- The "shape" of a value for profiling: 32-char hex ids → #, digits → 9, letter runs → a / A.
-- '02/10/2017 10:56' → '99/99/9999 99:99'   'R$ 81,16' → 'A$ 99,99'   ' 3f2a…' → ' #'
create or replace function cleaning.shape(v text) returns text
language sql immutable as $$
    select left(regexp_replace(regexp_replace(regexp_replace(regexp_replace(
               v, '[0-9a-f]{32}', '#', 'g'), '[0-9]', '9', 'g'), '[[:lower:]]+', 'a', 'g'), '[[:upper:]]+', 'A', 'g'), 40)
$$;

-- ---------- ops tables for the cleaning stage ----------

create table if not exists ops.cleaning_rules (
    rule_id         text primary key,      -- <proposal run id>:<source>:<number>
    run_id          text,                  -- the run in which the agent proposed the rule
    source          text,
    rule_order      integer,               -- rules are applied in this order
    rule_type       text,
    column_name     text,
    params          jsonb,
    reason          text,                  -- the agent's reason
    confidence      numeric,
    risk            text,                  -- safe / risky
    risk_reason     text,                  -- why the policy put it in that group
    status          text,                  -- auto / pending / approved / rejected / expired / invalid
    rows_affected   integer,               -- from the dry run when it was proposed
    examples        jsonb,                 -- up to 3 values before → after, from the dry run
    sql             text,                  -- what runs when the rule is applied (auto or approved)
    reject_sql      text,                  -- what runs when it is rejected: the bad values become null
    decided_by      text,
    decided_at      timestamptz,
    created_at      timestamptz default now()
);

create table if not exists ops.cleaning_approvals (
    run_id          text primary key,
    resume_url      text,                  -- the paused n8n execution continues when this URL is called
    status          text,                  -- waiting / submitted / expired
    rules_pending   integer,
    created_at      timestamptz default now(),
    submitted_at    timestamptz
);

create table if not exists ops.quarantine (
    id              bigserial primary key,
    run_id          text,
    source          text,
    rule_id         text,                  -- null when the final key check removed the row
    reason          text,
    record          jsonb,
    quarantined_at  timestamptz default now()
);
