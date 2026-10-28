# Dashboard: Metabase on the analytics tables

The dashboard stage (Milestone 5) shows the pipeline's results in Metabase. It reads only the tables the transformation and Explain workflows publish in `analytics`, plus `ops.agent_logs` for the activity panel. It never reads `clean`, `raw` or `models`. The joins were done at night, so the dashboard opens straight away.

| Piece | Where |
|---|---|
| Metabase (JAR + portable Java 21) | `%USERPROFILE%\metabase-local\` → http://localhost:3000 |
| Start script | `metabase/start_metabase.cmd` |
| Build script | `scripts/build_metabase_dashboard.py` (creates everything through the Metabase API) |
| Settings (optional) | `%USERPROFILE%\metabase-local\dashboard.env` (template: `metabase/dashboard.env.example`). Use it to skip typing the login, to pick one of several databases (`MB_DATABASE`), or to let the script set up a fresh Metabase and its database connection by itself |

---

## 1. What is on the dashboard

Dashboard **Olist sales** in the collection **Olist webinar** has two tabs. A second dashboard, **Olist late deliveries · drill-down**, opens from a cause.

**Overview:** the validated summary tables, exactly what the transformation checks passed, and the Explain stage's insights. Its only filter is **Explained month**, which the insight cards use.

| Card | Reads | Roadmap item |
|---|---|---|
| Data as of | `max(refreshed_at)` from `analytics.refresh_status` | the "last good run" stamp |
| What happened | `analytics.insight_summary`: one line per month the late rate moved. Clicking a month sets *Explained month* | M5: narrative card |
| Why it happened | `analytics.insight_causes` (causes): cause, explanation, points and stars recovered. Clicking a cause opens the drill-down with its filter | Explain stage |
| What to do | `analytics.insight_recommendations`: lever, action, the causes it fixes | Explain stage |
| Ruled out | `analytics.insight_causes` (ruled-out factors) | Explain stage |
| Revenue, Orders, Customers, Average order value, Average review score | `analytics.kpi_summary` | M5: KPI tiles |
| Revenue by month (revenue as a line, orders as bars) | `analytics.monthly_revenue` | M5: revenue trend |
| Revenue by customer state | `analytics.revenue_by_state` | M5: state breakdown |
| Top 10 categories by revenue | `analytics.top_categories` (`revenue_rank <= 10`) | M5: top products |
| Last run per agent, Agent activity (latest 100 rows) | `ops.agent_logs` | M5: activity panel |

**Explore:** the wide tables, with three filters: **Month**, **Customer state** and **Category**.

| Card | Reads | Filters |
|---|---|---|
| Revenue, Orders, Average order value, Items sold | `analytics.order_items_wide` | month, state, category |
| Revenue by month, Revenue by state, Top 10 categories | `analytics.order_items_wide` | month, state, category |
| Average delivery days, Late deliveries | `analytics.orders_wide` | month, state |
| Orders (latest 2,000) | `analytics.orders_wide` | month, state |

The category filter can't apply to the order-level cards, because an order can have items in several categories. With no filters set, the Explore numbers equal the Overview numbers. Both come from the same definitions and are reconciled against the same revenue in the transformation stage.

**Olist late deliveries · drill-down:** one segment of `analytics.order_facts`, with eight optional filters: Month (YYYY-MM), Customer state, Seller state, Cross-state, Seller shipped late, Multi-seller, Category and Seller. It shows the late rate, late and delivered orders, the average review, the segment's late rate by month, routes (seller state → customer state), categories and the late orders. A click on a cause fills the month and every `=` condition of the cause's filter. For example, the top March 2018 cause opens with Month 2018-03, Cross-state *yes* and Seller shipped late *no*: 4,036 orders, 954 late, worst route SP → RJ.

Every card is a SQL question: open it to show the audience the query behind a number.

---

## 2. Setup (once)

1. **Read-only login in Supabase.** In the SQL editor (after `scripts/transform_tables.sql`):

   ```sql
   create role metabase_reader login password 'choose-one' in role analytics_reader;
   ```

   Through the Session pooler its user name is `metabase_reader.<project-ref>`. It can read `analytics.*` and `ops.agent_logs` and nothing else.

2. **Start Metabase:** double-click `metabase\start_metabase.cmd` (or run it in a terminal). The first start takes 1–2 minutes. It is ready when the log shows `Metabase Initialization COMPLETE` and http://localhost:3000 opens.

3. **Set up Metabase in the browser** (admin account), and add the Supabase database under *Admin → Databases* with the `metabase_reader` login from step 1 (Session pooler host, port 5432, database `postgres`). Include at least the schemas `analytics` and `ops`.

4. **Build the dashboard** in a terminal:

   ```
   python -I scripts\build_metabase_dashboard.py
   ```

   It asks for your Metabase login, because the script talks to Metabase's API as a separate program and has to log in like any user. The login isn't stored. It finds the database connection that has `analytics.kpi_summary`, saves the 33 questions, lays out both dashboards and then runs every question once. It ends with one `ok` line per question and the dashboard link. Run it again whenever you change the script: everything is found by name and updated in place, so links and the dashboard URL stay the same.

---

## 3. Building it by hand (the webinar version)

To show how it works in the Metabase UI, build one or two cards live and let the script do the rest.

1. **New → SQL query**, database *Olist (Supabase)*: `select revenue from analytics.kpi_summary`. Visualization *Number*, then the gear icon → *Style: Currency, BRL*. Save it to *Olist webinar*.
2. **New → Question** (no SQL): *Analytics → Monthly Revenue*, then *Visualize* → *Line*, with X = Month and Y = Revenue.
3. **A filter:** on the dashboard, *Edit → Add a filter → Text or Category*, then connect it to *Customer State* on each card.
4. A SQL question with a filter needs a variable: `where {{state}}`, with the variable type *Field Filter* → *Order Items Wide → Customer State*.

Don't edit the cards the script made in the UI. The next script run overwrites them. Save your own copy instead (*… → Duplicate*).

---

## 4. Things to watch

- **The data is only as fresh as the last transformation run.** Check the *Data as of* card. If a transformation run failed (FR-T4), nothing was published and the dashboard keeps showing the last complete run. That is a good demo moment. The failure is visible in the activity panel.
- **Caching:** Metabase may show a result it fetched a few minutes ago. After a manual pipeline run, refresh the dashboard (↻ at the top right).
- **Orders without a purchase date** are left out of the monthly trends only, so the trend adds up to slightly less than the Revenue tile. `n8n/TRANSFORMATION.md` section 3 explains why.
- **(unknown) state:** orders whose customer was quarantined during cleaning. They are kept so the states add up to the total.
- **Pooler user name:** `metabase_reader.<project-ref>`, not just `metabase_reader`. Without the suffix the pooler refuses the login with "Tenant or user not found".
- **Metabase's own data** (users, questions, dashboards) is in `%USERPROFILE%\metabase-local\metabase.db.mv.db`. Copy that file to back it up, or run the script on a fresh Metabase to rebuild everything.
- **Insight cards are empty** until the Explain workflow has run (`n8n/EXPLAIN.md`). Run the build script again after `scripts/insights_tables.sql`, so Metabase sees the new tables.
- **Click-through not tested yet:** the click behaviors (month → filter, cause → drill-down) are set through the API and have not been tried in this Metabase version. If a click does nothing, set them by hand: *Edit dashboard → the card's ⋯ → Click behavior*. A cause with an empty `f_*` column should leave that drill-down filter empty; check that it does not filter on an empty value.
- **Next step:** the chat Q&A uses the same `analytics_reader` rights.
