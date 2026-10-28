-- Schemas, tables and functions for the Explain (insights) workflow. Run once in the Supabase SQL editor,
-- after scripts/transform_tables.sql. Safe to run again.
--
--   analytics.order_facts      one row per counted order with the columns a cause can be described by. Rebuilt
--                              from analytics.orders_wide / order_items_wide (and two dates in clean.*) at the
--                              start of every Explain run. The drill-down dashboard reads it too.
--   insights.kpi_config        one row per KPI: which orders count, what a gap order is, the columns the AI may
--                              break the KPI down by, the threshold and the levers it may recommend
--   insights.kpi_months()      the KPI per month against its baseline (median of the 3 months before)
--   insights.breakdowns()      the totals the AI reads: the KPI broken down by every approved column and pair
--   insights.size_cause()      measures one cause (a filter on approved columns): the AI never writes a number
--   analytics.insight_*        what the dashboard shows: summary, causes (and ruled-out factors), recommendations
--   insights.stage_*           rows of a run that is still going; insights.publish() moves them in one transaction
--
-- The AI never runs SQL. Its cause filters are turned into SQL here, only on approved columns, with every value
-- quoted (format %I / %L), so a filter can't reach anything else.

create schema if not exists insights;
create schema if not exists analytics;

-- ---------- order facts ----------

create table if not exists analytics.order_facts (
    order_id            text primary key,
    purchase_month      date,
    customer_state      text,
    seller_state        text,      -- the seller of the order's largest item
    seller_id           text,      -- the same seller
    category            text,      -- the category of the order's largest item
    cross_state         text,      -- 'yes' when no item ships from the customer's state
    multi_seller        text,      -- 'yes' when more than one seller ships the order
    seller_shipped_late text,      -- 'yes' when the seller handed the parcel to the carrier after the shipping limit
    delivery_band       text,      -- '0-7 days', '8-14 days', '15-30 days', 'over 30 days'
    delivery_days       integer,
    is_late             boolean,   -- as in analytics.orders_wide (dates compared, not times)
    review_score        numeric,
    revenue             numeric
);
create index if not exists order_facts_purchase_month_idx on analytics.order_facts (purchase_month);

-- Flags are text ('yes' / 'no') so the AI, the sizing query and the Metabase filters all use the same values.
-- plpgsql resolves table names when it runs, so this can be created before transformation has published anything.
create or replace function insights.refresh_order_facts() returns bigint
language plpgsql as $$
declare
    v_rows bigint;
begin
    truncate analytics.order_facts;
    insert into analytics.order_facts
    with items as (
        select i.order_id,
               count(distinct i.seller_id) as sellers,
               max(ci.shipping_limit_date) as shipping_limit,
               array_agg(distinct i.seller_state) filter (where i.seller_state is not null) as seller_states
        from analytics.order_items_wide i
             join clean.order_items ci on ci.order_id = i.order_id and ci.order_item_id = i.order_item_id
        group by i.order_id),
    main as (
        select distinct on (order_id) order_id, seller_id, seller_state, category
        from analytics.order_items_wide
        order by order_id, revenue desc nulls last, order_item_id)
    select o.order_id, o.purchase_month, o.customer_state, m.seller_state, m.seller_id, m.category,
           case when o.customer_state is null or it.seller_states is null then null
                when o.customer_state = any(it.seller_states) then 'no' else 'yes' end,
           case when it.sellers > 1 then 'yes' else 'no' end,
           case when co.order_delivered_carrier_date is null or it.shipping_limit is null then null
                when co.order_delivered_carrier_date > it.shipping_limit then 'yes' else 'no' end,
           case when o.delivery_days is null then null
                when o.delivery_days <= 7 then '0-7 days'
                when o.delivery_days <= 14 then '8-14 days'
                when o.delivery_days <= 30 then '15-30 days'
                else 'over 30 days' end,
           o.delivery_days, o.is_late, o.review_score, o.revenue
    from analytics.orders_wide o
         left join items it on it.order_id = o.order_id
         left join main m on m.order_id = o.order_id
         left join clean.orders co on co.order_id = o.order_id;
    get diagnostics v_rows = row_count;
    analyze analytics.order_facts;
    return v_rows;
end $$;

-- ---------- KPI settings ----------

create table if not exists insights.kpi_config (
    kpi_id          text primary key,
    name            text,
    definition      text,          -- shown to the AI
    population      text,          -- SQL condition on analytics.order_facts: the orders the rate counts
    gap             text,          -- SQL condition: a gap order (late, low review, ...)
    gap_noun        text,          -- 'late orders'
    columns         jsonb,         -- approved columns: what the KPI is broken down by and causes are described by
    pairs           jsonb,         -- pairs of columns broken down together, e.g. [["cross_state", "seller_shipped_late"]]
    top_rows        integer,       -- rows kept per breakdown, largest excess first
    threshold_ratio numeric,       -- a month moved when its rate is at least this many times the baseline
    min_rise        numeric,       -- ... and at least this much above it (0.02 = 2 points)
    min_orders      integer,       -- months with fewer counted orders are not explained
    min_gap_orders  integer,
    impact          jsonb,         -- cross-KPI effect sized with each cause: {"column": "review_score", "noun": "review stars"}
    levers          jsonb,         -- {"lever_key": "what it means"}: the only levers a recommendation may use
    enabled         boolean default true,
    updated_at      timestamptz default now()
);

alter table insights.kpi_config add column if not exists min_rise numeric;

-- KPI rows are written by people, not by the workflow. Review score and orders/revenue can be added as rows later.
insert into insights.kpi_config (kpi_id, name, definition, population, gap, gap_noun, columns, pairs, top_rows,
                                 threshold_ratio, min_rise, min_orders, min_gap_orders, impact, levers)
values ('late_delivery_rate', 'Late delivery rate',
        'Share of delivered orders that arrived after the promised delivery date (dates compared, not times).',
        'is_late is not null', 'is_late', 'late orders',
        '["customer_state", "seller_state", "cross_state", "seller_shipped_late", "multi_seller", "category", "seller_id"]',
        '[["cross_state", "seller_shipped_late"], ["seller_state", "customer_state"]]',
        12, 1.5, 0.02, 500, 100,
        '{"column": "review_score", "noun": "review stars"}',
        '{"carrier_route":  "work with the carrier on specific routes: escalate, change carrier, add a second carrier",
          "seller_dispatch": "rules and support for sellers to hand parcels to the carrier by the shipping limit",
          "promised_date":  "change the delivery date promised to customers on specific routes or periods",
          "peak_capacity":  "book carrier and seller capacity ahead of known peak periods",
          "ship_together":  "consolidate orders from several sellers, or tell customers they arrive in parts",
          "listing_quality": "improve product descriptions, photos or quality in specific categories"}')
on conflict (kpi_id) do update
    set name = excluded.name, definition = excluded.definition, population = excluded.population,
        gap = excluded.gap, gap_noun = excluded.gap_noun, columns = excluded.columns, pairs = excluded.pairs,
        top_rows = excluded.top_rows, threshold_ratio = excluded.threshold_ratio, min_rise = excluded.min_rise,
        min_orders = excluded.min_orders,
        min_gap_orders = excluded.min_gap_orders, impact = excluded.impact, levers = excluded.levers,
        updated_at = now();

create or replace function insights.config(p_kpi text) returns insights.kpi_config
language plpgsql stable as $$
declare
    v insights.kpi_config;
begin
    select * into v from insights.kpi_config where kpi_id = p_kpi;
    if not found then
        raise exception 'insights: unknown KPI %', p_kpi;
    end if;
    return v;
end $$;

-- ---------- the KPI per month ----------

-- One row per month with at least min_orders counted orders. baseline_rate = median rate of the 3 calendar months
-- before (at least 2 of them must have enough orders). moved = the rate reached threshold_ratio × baseline and
-- min_rise above it, with at least min_gap_orders gap orders.
create or replace function insights.kpi_months(p_kpi text)
returns table (month date, orders integer, prev_orders integer, counted integer, gap_orders integer,
               rate numeric, baseline_rate numeric, baseline_months integer, ratio numeric, moved boolean)
language plpgsql stable as $$
declare
    k insights.kpi_config := insights.config(p_kpi);
begin
    return query execute format($q$
        with m as (
            select purchase_month as month, count(*) as all_orders,
                   count(*) filter (where %1$s) as pop,
                   count(*) filter (where (%1$s) and (%2$s)) as gap
            from analytics.order_facts where purchase_month is not null group by 1),
        r as (select m.*, m.gap::numeric / m.pop as rate from m where m.pop >= $1),
        b as (
            select r.month,
                   (select percentile_cont(0.5) within group (order by p.rate)
                    from r p where p.month >= r.month - 3 * interval '1 month' and p.month < r.month)::numeric as base,
                   (select count(*) from r p
                    where p.month >= r.month - 3 * interval '1 month' and p.month < r.month)::int as n
            from r)
        select r.month, r.all_orders::int,
               (select m2.all_orders::int from m m2 where m2.month = (r.month - interval '1 month')::date),
               r.pop::int, r.gap::int, round(r.rate, 4), round(b.base, 4), b.n,
               round(r.rate / nullif(b.base, 0), 2),
               coalesce(b.n >= 2 and r.rate >= b.base * $2 and r.rate - b.base >= $4 and r.gap >= $3, false)
        from r join b on b.month = r.month
        order by r.month
    $q$, k.population, k.gap) using k.min_orders, k.threshold_ratio, k.min_gap_orders, k.min_rise;
end $$;

-- ---------- breakdowns: what the AI reads ----------

-- The KPI in p_month broken down by p_cols (one column, or several together). For each value: counted orders, gap
-- orders, the rate, the value's own baseline (median of its rate in the 3 months before), its share of the gap, and
-- excess_gap_orders = gap orders above what its baseline rate would give. Largest excess first, top_rows rows.
create or replace function insights.breakdown(p_kpi text, p_month date, p_cols text[])
returns jsonb
language plpgsql stable as $$
declare
    k        insights.kpi_config := insights.config(p_kpi);
    v_bad    text[] := array(select c from unnest(p_cols) c where not k.columns ? c);
    v_base   numeric;
    v_seg    text;
    v_result jsonb;
begin
    if cardinality(v_bad) > 0 or cardinality(p_cols) = 0 then
        raise exception 'insights: not approved columns for %: %', p_kpi, array_to_string(v_bad, ', ');
    end if;
    select m.baseline_rate into v_base from insights.kpi_months(p_kpi) m where m.month = p_month;
    v_seg := format('jsonb_build_object(%s)', (select string_agg(format('%L, %I', c, c), ', ') from unnest(p_cols) c));
    execute format($q$
        with f as (
            select %1$s as seg, purchase_month as month, coalesce((%2$s), false) as is_gap
            from analytics.order_facts
            where (%3$s) and purchase_month >= $1 - 3 * interval '1 month' and purchase_month <= $1),
        per as (select seg, month, count(*) as n, count(*) filter (where is_gap) as g from f group by seg, month),
        cur as (select seg, n, g from per where month = $1),
        base as (select seg, percentile_cont(0.5) within group (order by g::numeric / n)::numeric as rate
                 from per where month < $1 group by seg),
        tot as (select sum(g) as g from cur),
        seg_rows as (
            select cur.seg, cur.n, cur.g, base.rate as base, tot.g as tot_g,
                   cur.g - cur.n * coalesce(base.rate, $2) as excess
            from cur left join base on base.seg = cur.seg cross join tot)
        select coalesce(jsonb_agg(jsonb_build_object(
                   'value', seg, 'orders', n, 'gap_orders', g, 'rate', round(g::numeric / n, 4),
                   'baseline_rate', round(base, 4), 'share_of_gap', round(g::numeric / nullif(tot_g, 0), 4),
                   'excess_gap_orders', round(excess)) order by excess desc), '[]')
        from (select * from seg_rows order by excess desc limit $3) t
    $q$, v_seg, k.gap, k.population) into v_result using p_month, coalesce(v_base, 0), k.top_rows;
    return v_result;
end $$;

-- Every breakdown for one KPI and month: each approved column on its own, then each pair.
-- {"customer_state": [...], "cross_state x seller_shipped_late": [...], ...}
create or replace function insights.breakdowns(p_kpi text, p_month date)
returns jsonb
language plpgsql stable as $$
declare
    k      insights.kpi_config := insights.config(p_kpi);
    v_out  jsonb := '{}';
    v_col  text;
    v_pair jsonb;
    v_cols text[];
begin
    for v_col in select jsonb_array_elements_text(k.columns) loop
        v_out := v_out || jsonb_build_object(v_col, insights.breakdown(p_kpi, p_month, array[v_col]));
    end loop;
    for v_pair in select jsonb_array_elements(coalesce(k.pairs, '[]')) loop
        v_cols := array(select jsonb_array_elements_text(v_pair));
        v_out := v_out || jsonb_build_object(array_to_string(v_cols, ' x '), insights.breakdown(p_kpi, p_month, v_cols));
    end loop;
    return v_out;
end $$;

-- ---------- sizing: how big a cause is ----------

-- Turns a cause filter into a SQL condition, or raises an error that says what is wrong with it.
-- p_filter: [{"column": "cross_state", "op": "=", "value": "yes"}, {"column": "category", "op": "in", "value": [...]}]
-- Values true / false are read as 'yes' / 'no', the values of the flag columns.
create or replace function insights.filter_sql(p_kpi text, p_filter jsonb)
returns text
language plpgsql stable as $$
declare
    k      insights.kpi_config := insights.config(p_kpi);
    v_cond jsonb;
    v_col  text;
    v_op   text;
    v_val  jsonb;
    v_vals text[];
    v_sql  text[] := '{}';
    v_text text;
begin
    if p_filter is null or jsonb_typeof(p_filter) <> 'array' then
        raise exception 'the filter must be a list of conditions';
    end if;
    for v_cond in select jsonb_array_elements(p_filter) loop
        v_col := v_cond ->> 'column';
        v_op := lower(coalesce(v_cond ->> 'op', ''));
        v_val := v_cond -> 'value';
        if v_col is null or not k.columns ? v_col then
            raise exception 'column "%" is not approved; allowed: %', v_col,
                (select string_agg(c, ', ') from jsonb_array_elements_text(k.columns) c);
        end if;
        if v_op in ('=', '!=') then
            if v_val is null or jsonb_typeof(v_val) in ('array', 'object', 'null') then
                raise exception 'column "%": operator % needs one value', v_col, v_op;
            end if;
            v_text := case jsonb_typeof(v_val) when 'boolean' then case when v_val::text = 'true' then 'yes' else 'no' end
                           else v_val #>> '{}' end;
            v_sql := v_sql || case when v_op = '=' then format('%I = %L', v_col, v_text)
                                   else format('%I is distinct from %L', v_col, v_text) end;
        elsif v_op = 'in' then
            if v_val is null or jsonb_typeof(v_val) <> 'array' or jsonb_array_length(v_val) = 0 then
                raise exception 'column "%": operator in needs a list of values', v_col;
            end if;
            v_vals := array(select case jsonb_typeof(e) when 'boolean' then case when e::text = 'true' then 'yes' else 'no' end
                                        else e #>> '{}' end
                            from jsonb_array_elements(v_val) e);
            v_sql := v_sql || format('%I = any(%L::text[])', v_col, v_vals);
        else
            raise exception 'column "%": operator "%" is not allowed; use =, != or in', v_col, v_cond ->> 'op';
        end if;
    end loop;
    return coalesce(nullif(array_to_string(v_sql, ' and '), ''), 'true');
end $$;

-- Measures one cause in p_month. Never raises: a bad filter comes back as {"ok": false, "error": "..."}.
--   matched_orders, gap_orders, rate      the cause's orders this month
--   baseline_rate                         the same orders' median rate in the 3 months before (KPI baseline if none)
--   excess_gap_orders                     gap orders above that baseline
--   points_recovered                      how many points the month's rate drops if the excess goes away
--   impact_recovered                      cross-KPI: e.g. review stars the month gains if the excess goes away
-- An empty filter matches every counted order: the workflow uses it to reconcile with kpi_months.
create or replace function insights.size_cause(p_kpi text, p_month date, p_filter jsonb)
returns jsonb
language plpgsql stable as $$
declare
    k      insights.kpi_config := insights.config(p_kpi);
    v_cond text;
    v_base numeric;
    v_imp  text := coalesce(quote_ident(k.impact ->> 'column'), 'null::numeric');
    v_r    record;
begin
    begin
        v_cond := insights.filter_sql(p_kpi, p_filter);
    exception when others then
        return jsonb_build_object('ok', false, 'error', sqlerrm);
    end;
    select m.baseline_rate into v_base from insights.kpi_months(p_kpi) m where m.month = p_month;
    execute format($q$
        with f as (
            select purchase_month as month, coalesce((%1$s), false) as is_gap, coalesce((%2$s), false) as hit,
                   %3$s as impact
            from analytics.order_facts
            where (%4$s) and purchase_month >= $1 - 3 * interval '1 month' and purchase_month <= $1),
        prior as (select month, count(*) as n, count(*) filter (where is_gap) as g
                  from f where hit and month < $1 group by month)
        select count(*) filter (where month = $1) as all_n,
               count(*) filter (where month = $1 and is_gap) as all_g,
               count(*) filter (where month = $1 and hit) as n,
               count(*) filter (where month = $1 and hit and is_gap) as g,
               (select percentile_cont(0.5) within group (order by g::numeric / n) from prior)::numeric as base,
               avg(impact) filter (where month = $1 and not is_gap) as imp_ok,
               avg(impact) filter (where month = $1 and is_gap) as imp_gap,
               count(impact) filter (where month = $1) as imp_n
        from f
    $q$, k.gap, v_cond, v_imp, k.population) into v_r using p_month;

    return jsonb_build_object(
        'ok', true, 'condition', v_cond,
        'month_orders', v_r.all_n, 'month_gap_orders', v_r.all_g,
        'month_rate', round(v_r.all_g::numeric / nullif(v_r.all_n, 0), 4), 'month_baseline_rate', v_base,
        'matched_orders', v_r.n, 'gap_orders', v_r.g,
        'rate', round(v_r.g::numeric / nullif(v_r.n, 0), 4),
        'baseline_rate', round(coalesce(v_r.base, v_base), 4),
        'share_of_gap', round(v_r.g::numeric / nullif(v_r.all_g, 0), 4),
        'excess_gap_orders', round(v_r.g - v_r.n * coalesce(v_r.base, v_base, 0)),
        'points_recovered', round(100 * (v_r.g - v_r.n * coalesce(v_r.base, v_base, 0)) / nullif(v_r.all_n, 0), 1),
        'impact_recovered', round((v_r.g - v_r.n * coalesce(v_r.base, v_base, 0)) * (v_r.imp_ok - v_r.imp_gap)
                                  / nullif(v_r.imp_n, 0), 2));
end $$;

-- ---------- what the dashboard reads ----------

create table if not exists analytics.insight_summary (
    run_id          text,
    kpi_id          text,
    kpi_name        text,
    month           date,
    headline        text,          -- the AI's "what happened", placeholders filled
    rate            numeric,       -- the month's KPI value (0-1)
    baseline_rate   numeric,
    orders          integer,
    prev_orders     integer,
    causes          integer,       -- causes that passed the checks
    status          text,          -- explained / partly_explained (some items dropped) / not_explained
    generated_at    timestamptz default now(),
    primary key (kpi_id, month)
);

create table if not exists analytics.insight_causes (
    run_id              text,
    kpi_id              text,
    month               date,
    kind                text,      -- cause / ruled_out
    cause_key           text,
    cause_name          text,
    explanation         text,      -- placeholders filled
    cause_filter        jsonb,     -- the AI's filter: also what the drill-down opens with
    supporting_cuts     jsonb,     -- the breakdowns that show it
    matched_orders      integer,
    gap_orders          integer,
    rate                numeric,
    baseline_rate       numeric,
    share_of_gap        numeric,
    points_recovered    numeric,
    impact_recovered    numeric,
    rank                integer,   -- by points_recovered within the KPI and month (ruled-out factors: null)
    -- Drill-down filters: the value of each '=' condition, null when the filter does not fix the column
    f_customer_state    text,
    f_seller_state      text,
    f_cross_state       text,
    f_seller_shipped_late text,
    f_multi_seller      text,
    f_category          text,
    f_seller_id         text,
    primary key (kpi_id, month, kind, cause_key)
);

create table if not exists analytics.insight_recommendations (
    run_id              text,
    kpi_id              text,
    month               date,
    reco_key            text,
    lever               text,
    action              text,
    closes_cause_keys   jsonb,
    closes_cause_names  text,
    points_recovered    numeric,   -- the largest points_recovered of the causes it closes
    rank                integer,
    primary key (kpi_id, month, reco_key)
);

create table if not exists insights.stage_summary (like analytics.insight_summary);
create table if not exists insights.stage_causes (like analytics.insight_causes);
create table if not exists insights.stage_recommendations (like analytics.insight_recommendations);

-- Moves a run's staged rows into analytics in one transaction, so the dashboard never shows half a run.
-- p_full = true (a run over every moved month): the KPI's old rows go too, so months that no longer move disappear.
-- Otherwise only the months in this run are replaced.
create or replace function insights.publish(p_run_id text, p_full boolean)
returns integer
language plpgsql as $$
declare
    v_rows integer;
begin
    create temp table _months on commit drop as
        select distinct kpi_id, month from insights.stage_summary where run_id = p_run_id;
    if p_full then
        delete from analytics.insight_summary t where t.kpi_id in (select kpi_id from _months);
        delete from analytics.insight_causes t where t.kpi_id in (select kpi_id from _months);
        delete from analytics.insight_recommendations t where t.kpi_id in (select kpi_id from _months);
    else
        delete from analytics.insight_summary t using _months m where t.kpi_id = m.kpi_id and t.month = m.month;
        delete from analytics.insight_causes t using _months m where t.kpi_id = m.kpi_id and t.month = m.month;
        delete from analytics.insight_recommendations t using _months m where t.kpi_id = m.kpi_id and t.month = m.month;
    end if;
    insert into analytics.insight_summary select * from insights.stage_summary where run_id = p_run_id;
    get diagnostics v_rows = row_count;
    insert into analytics.insight_causes select * from insights.stage_causes where run_id = p_run_id;
    insert into analytics.insight_recommendations select * from insights.stage_recommendations where run_id = p_run_id;
    delete from insights.stage_summary where run_id = p_run_id;
    delete from insights.stage_causes where run_id = p_run_id;
    delete from insights.stage_recommendations where run_id = p_run_id;

    insert into analytics.refresh_status (table_name, row_count, run_id, refreshed_at)
    select t, (case t when 'insight_summary' then (select count(*) from analytics.insight_summary)
                      when 'insight_causes' then (select count(*) from analytics.insight_causes)
                      else (select count(*) from analytics.insight_recommendations) end), p_run_id, now()
    from unnest(array['insight_summary', 'insight_causes', 'insight_recommendations']) t
    on conflict (table_name) do update
        set row_count = excluded.row_count, run_id = excluded.run_id, refreshed_at = excluded.refreshed_at;
    return v_rows;
end $$;

-- ---------- rights ----------

grant select on analytics.order_facts, analytics.insight_summary, analytics.insight_causes,
                analytics.insight_recommendations to analytics_reader;
