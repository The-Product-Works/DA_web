-- Schemas, roles and helpers for the transformation workflow. Run once in the Supabase SQL editor,
-- after scripts/clean_tables.sql. Safe to run again.
--
--   models.*                the views the transformation agent creates and the checks validate (FR-T2):
--                           the only thing it can write
--   analytics.*             tables published from the models once every view passed: what Metabase and the chat
--                           read, so the dashboard never waits for the pipeline
--   analytics.refresh_status  when each analytics table was last published, and from which run
--   transform.*             helper functions that validate and publish (the agent cannot reach them)
--   ops.transform_models    every SQL the agent wrote, with its checks and whether it passed (FR-T5)
--   role transform_agent    the agent's SQL runs as this role: reads clean.*, creates views in models, nothing else
--   role analytics_reader   read-only role for Metabase and the chat Q&A: reads analytics.* (and the activity log)

create schema if not exists models;
create schema if not exists analytics;
create schema if not exists transform;
create schema if not exists ops;

-- ---------- roles ----------

do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'transform_agent') then
        create role transform_agent nologin;
    end if;
    if not exists (select 1 from pg_roles where rolname = 'analytics_reader') then
        create role analytics_reader nologin;
    end if;
end $$;

-- The workflow's connection switches to transform_agent with SET LOCAL ROLE while the agent's view is created
grant transform_agent to current_user;

grant usage on schema clean to transform_agent;
grant select on all tables in schema clean to transform_agent;
alter default privileges in schema clean grant select on tables to transform_agent;
grant usage, create on schema models to transform_agent;
-- An earlier version of this file let the agent create views in analytics; now only the publish step writes there
revoke create on schema analytics from transform_agent;

grant usage on schema analytics to analytics_reader;
grant select on all tables in schema analytics to analytics_reader;
alter default privileges in schema analytics grant select on tables to analytics_reader;
-- The dashboard's agent activity panel reads the log
grant usage on schema ops to analytics_reader;
grant select on ops.agent_logs to analytics_reader;

-- For Metabase and the chat Q&A, create a login with the reader's rights (choose your own password).
-- Through the Supabase pooler its user name becomes metabase_reader.<project-ref>.
--   create role metabase_reader login password 'change-me' in role analytics_reader;

-- ---------- indexes for the joins the views use ----------
-- The clean tables only have their primary keys. These columns are joined on but are not the first column of a
-- key; without an index, joining reviews to orders scans the whole reviews index once per order.

create index if not exists reviews_order_id_idx on clean.reviews (order_id);
create index if not exists orders_customer_id_idx on clean.orders (customer_id);
create index if not exists order_items_product_id_idx on clean.order_items (product_id);
analyze clean.orders, clean.order_items, clean.customers, clean.products, clean.category_translation,
        clean.payments, clean.reviews;

-- ---------- the SQL the agent wrote ----------

create table if not exists ops.transform_models (
    model_id        text primary key,      -- <run id>:<view>:<attempt>
    run_id          text,
    view_name       text,
    question        text,
    spec_hash       text,                  -- changes when the question, columns or definitions change
    attempt         integer,               -- 1, or 2 after the agent's repair try
    origin          text,                  -- agent / repair / stored (SQL that passed in an earlier run)
    select_sql      text,                  -- the agent's SELECT
    view_sql        text,                  -- the statement that created the view
    explanation     text,
    assumptions     jsonb,
    status          text,                  -- passed / failed
    checks          jsonb,                 -- the validation results
    error           text,                  -- why it failed
    created_at      timestamptz default now()
);

-- ---------- validation ----------

-- Groups column types for the column check: integer and numeric are both 'number', date and timestamp both 'time'
create or replace function transform.type_group(t text) returns text
language sql immutable as $$
    select case
        when t in ('smallint', 'integer', 'bigint', 'real', 'double precision') or t like 'numeric%' then 'number'
        when t = 'date' or t like 'timestamp%' then 'time'
        when t in ('text', 'name') or t like 'character%' or t like 'varchar%' then 'text'
        else t end
$$;

-- FR-T3. Checks a view in models against its spec and returns the results. Raises an error when a check fails,
-- so the transaction that created the view rolls back and the previous version of the view stays (FR-T4).
--
-- p_spec: {"columns": {"month": "date", "revenue": "numeric"}, "grain": ["month"], "min_rows": 1,
--          "reference_sql": "select ...",                         hand-written answer the view must match
--          "reconcile": {"column": "revenue", "expected_sql": "select sum(...) ..."}}   optional
create or replace function transform.validate_view(p_view text, p_spec jsonb) returns jsonb
language plpgsql as $$
declare
    v_rel       regclass := to_regclass(format('models.%I', p_view));
    v_cols      text[] := array(select jsonb_object_keys(p_spec -> 'columns'));
    v_grain     text[] := array(select jsonb_array_elements_text(coalesce(p_spec -> 'grain', '[]')));
    v_actual    jsonb;
    v_missing   text[];
    v_extra     text[];
    v_wrong     text[];
    v_rows      bigint;
    v_dupes     bigint;
    v_total     numeric;
    v_expected  numeric;
    v_tolerance numeric;
    v_key       text;
    v_differs   text;
    v_mismatch  bigint;
    v_examples  jsonb;
    v_checks    jsonb := '[]';
    v_result    jsonb;
begin
    if v_rel is null then
        raise exception 'view failed validation: %', jsonb_build_object('passed', false, 'checks', jsonb_build_array(
            jsonb_build_object('check', 'view exists', 'passed', false, 'detail', format('models.%s was not created', p_view))));
    end if;

    -- 1. The columns asked for, with matching types, and nothing else
    select jsonb_object_agg(attname, format_type(atttypid, atttypmod)) into v_actual
    from pg_attribute where attrelid = v_rel and attnum > 0 and not attisdropped;
    v_missing := array(select c from unnest(v_cols) c where not v_actual ? c);
    v_extra := array(select k from jsonb_object_keys(v_actual) k where not k = any(v_cols));
    v_wrong := array(select format('%s is %s, expected %s', c, v_actual ->> c, p_spec -> 'columns' ->> c)
                     from unnest(v_cols) c
                     where v_actual ? c
                       and transform.type_group(v_actual ->> c) <> transform.type_group(p_spec -> 'columns' ->> c));
    v_checks := v_checks || jsonb_build_object('check', 'columns',
        'passed', cardinality(v_missing) + cardinality(v_extra) + cardinality(v_wrong) = 0,
        'detail', concat_ws('; ',
            case when cardinality(v_missing) > 0 then 'missing: ' || array_to_string(v_missing, ', ') end,
            case when cardinality(v_extra) > 0 then 'not asked for: ' || array_to_string(v_extra, ', ') end,
            case when cardinality(v_wrong) > 0 then 'wrong type: ' || array_to_string(v_wrong, ', ') end,
            case when cardinality(v_missing) + cardinality(v_extra) + cardinality(v_wrong) = 0
                 then cardinality(v_cols) || ' columns as specified' end));
    if cardinality(v_missing) + cardinality(v_extra) + cardinality(v_wrong) > 0 then
        -- The other checks need the right columns
        raise exception 'view failed validation: %', jsonb_build_object('passed', false, 'checks', v_checks);
    end if;

    -- 2. Row count
    execute format('select count(*) from %s', v_rel) into v_rows;
    v_checks := v_checks || jsonb_build_object('check', 'row count',
        'passed', v_rows >= coalesce((p_spec ->> 'min_rows')::int, 1),
        'detail', format('%s rows (at least %s expected)', v_rows, coalesce((p_spec ->> 'min_rows')::int, 1)));

    -- 3. No duplicate keys: one row per grain value (or exactly one row when there is no grain)
    if cardinality(v_grain) = 0 then
        v_checks := v_checks || jsonb_build_object('check', 'one row', 'passed', v_rows = 1,
            'detail', format('%s rows, exactly 1 expected', v_rows));
    else
        execute format('select count(*) from (select 1 from %s group by %s having count(*) > 1) d', v_rel,
                       (select string_agg(quote_ident(g), ', ') from unnest(v_grain) g)) into v_dupes;
        v_checks := v_checks || jsonb_build_object('check', 'no duplicate keys', 'passed', v_dupes = 0,
            'detail', format('%s values of (%s) appear more than once', v_dupes, array_to_string(v_grain, ', ')));
    end if;

    -- 4. The view's revenue adds up to the revenue in the clean tables (each row may round by up to 0.005)
    if p_spec ? 'reconcile' then
        execute format('select sum(%I) from %s', p_spec -> 'reconcile' ->> 'column', v_rel) into v_total;
        execute p_spec -> 'reconcile' ->> 'expected_sql' into v_expected;
        v_tolerance := 0.01 + 0.005 * v_rows;
        v_checks := v_checks || jsonb_build_object('check', 'revenue reconciles',
            'passed', abs(coalesce(v_total, 0) - coalesce(v_expected, 0)) <= v_tolerance,
            'detail', format('view total %s, clean tables %s, difference %s', round(coalesce(v_total, 0), 2),
                             round(coalesce(v_expected, 0), 2), round(coalesce(v_total, 0) - coalesce(v_expected, 0), 2)));
    end if;

    -- 5. Same rows and numbers as the hand-written reference SQL (numbers may differ by one cent from rounding)
    if p_spec ? 'reference_sql' then
        v_key := case when cardinality(v_grain) = 0 then '''1'''
                      else (select string_agg(format('coalesce(%I::text, ''<null>'')', g), ' || ''|'' || ') from unnest(v_grain) g) end;
        v_differs := (select string_agg(case
                          when transform.type_group(p_spec -> 'columns' ->> c) = 'number'
                          then format('(abs(coalesce(a.%1$I, 0) - coalesce(b.%1$I, 0)) > 0.011 or (a.%1$I is null) <> (b.%1$I is null))', c)
                          else format('(a.%1$I is distinct from b.%1$I)', c) end, ' or ')
                      from unnest(v_cols) c);
        begin
            execute format($q$
                with a as (select %1$s as _k, v.* from %2$s v),
                     b as (select %1$s as _k, r.* from (%3$s) r),
                     d as (select to_jsonb(a) - '_k' as view_row, to_jsonb(b) - '_k' as expected_row
                           from a full join b on a._k = b._k
                           where a._k is null or b._k is null or %4$s)
                select count(*), coalesce(jsonb_agg(jsonb_build_object('view', view_row, 'expected', expected_row))
                                          filter (where n <= 3), '[]')
                from (select d.*, row_number() over () as n from d) x
            $q$, v_key, v_rel, p_spec ->> 'reference_sql', v_differs) into v_mismatch, v_examples;
            v_checks := v_checks || jsonb_build_object('check', 'matches reference', 'passed', v_mismatch = 0,
                'detail', format('%s rows differ from the hand-written reference query', v_mismatch),
                'examples', v_examples);
        exception when others then
            v_checks := v_checks || jsonb_build_object('check', 'matches reference', 'passed', false,
                'detail', 'could not compare with the reference query: ' || sqlerrm);
        end;
    end if;

    v_result := jsonb_build_object('passed', not exists (select 1 from jsonb_array_elements(v_checks) c
                                                         where not (c ->> 'passed')::boolean),
                                   'row_count', v_rows, 'checks', v_checks);
    if not (v_result ->> 'passed')::boolean then
        raise exception 'view failed validation: %', v_result;
    end if;
    return v_result;
end $$;

-- ---------- publishing: models (views) → analytics (tables) ----------

create table if not exists analytics.refresh_status (
    table_name      text primary key,
    row_count       bigint,
    run_id          text,                  -- the transformation run that published it
    refreshed_at    timestamptz
);
grant select on analytics.refresh_status to analytics_reader;

-- Copies models.<view> into the table analytics.<view>, adds its indexes and records the refresh.
-- The table is emptied and refilled rather than dropped, so Metabase keeps its saved questions on it; it is only
-- rebuilt when the view's columns changed. Called by the workflow for every view in one transaction, after all of
-- them passed validation, so the dashboard always shows one complete run.
-- p_indexes: [["purchase_month"], ["customer_state"], ...], one column list per index
create or replace function transform.publish(p_view text, p_run_id text, p_indexes jsonb default '[]')
returns bigint
language plpgsql as $$
declare
    v_target    regclass := to_regclass(format('analytics.%I', p_view));
    v_source    regclass := to_regclass(format('models.%I', p_view));
    v_cols      text;
    v_index     jsonb;
    v_rows      bigint;
begin
    if v_source is null then
        raise exception 'publish: models.% does not exist', p_view;
    end if;
    if v_target is not null and (select relkind from pg_class where oid = v_target) <> 'r' then
        -- An analytics view from the earlier, views-only version of this workflow
        execute format('drop view %s', v_target);
        v_target := null;
    end if;
    if v_target is not null and
       (select array_agg(attname || ' ' || format_type(atttypid, atttypmod) order by attnum)
        from pg_attribute where attrelid = v_target and attnum > 0 and not attisdropped) is distinct from
       (select array_agg(attname || ' ' || format_type(atttypid, atttypmod) order by attnum)
        from pg_attribute where attrelid = v_source and attnum > 0 and not attisdropped) then
        execute format('drop table %s', v_target);
        v_target := null;
    end if;
    if v_target is null then
        execute format('create table analytics.%I as select * from models.%I with no data', p_view, p_view);
    end if;
    execute format('truncate analytics.%I', p_view);
    execute format('insert into analytics.%I select * from models.%I', p_view, p_view);
    get diagnostics v_rows = row_count;

    for v_index in select * from jsonb_array_elements(p_indexes) loop
        v_cols := (select string_agg(quote_ident(c), ', ') from jsonb_array_elements_text(v_index) c);
        execute format('create index if not exists %I on analytics.%I (%s)',
                       left(p_view || '_' || (select string_agg(c, '_') from jsonb_array_elements_text(v_index) c), 55) || '_idx',
                       p_view, v_cols);
    end loop;
    execute format('grant select on analytics.%I to analytics_reader', p_view);
    execute format('analyze analytics.%I', p_view);

    insert into analytics.refresh_status (table_name, row_count, run_id, refreshed_at)
    values (p_view, v_rows, p_run_id, now())
    on conflict (table_name) do update
        set row_count = excluded.row_count, run_id = excluded.run_id, refreshed_at = excluded.refreshed_at;
    return v_rows;
end $$;
