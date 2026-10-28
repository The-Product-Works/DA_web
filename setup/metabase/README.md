# Metabase setup for the Olist Data Analytics Pipeline

This folder provides a self-hosted Metabase option and the steps to connect it to the pipeline's PostgreSQL database. Metabase is a dashboard/query layer: it reads published `analytics` tables and selected operational logs; it does not run collection, cleaning, transformation, or Explain workflows.

## Dataset note

No Olist dataset is packaged or uploaded with this project. Metabase does not ingest source CSVs from the `data/` folder; it connects to PostgreSQL and visualizes the tables published by the collection, cleaning, transformation, and Explain stages. You can keep the project `data/` folder empty until you choose to add local files. If your workflow uses the documented Google Drive/Sheets/API sources, configure those sources separately and ensure the pipeline has successfully populated the database before expecting dashboard results.

## What is included and what is not

- `docker-compose.yml`: starts Metabase in Docker and persists its local application database in a named Docker volume.
- `DASHBOARD.md`: dashboard/table design notes carried over from the supplied project materials.
- `dashboard.env.example`: a reference template for database connection values; it is **not** automatically loaded by Docker Compose and should not contain real secrets when committed.

The supplied archives refer to `scripts/build_metabase_dashboard.py` and a Windows `metabase/start_metabase.cmd`, but neither file was present in the supplied ZIPs or this setup package. Therefore, this package does not claim to auto-build the dashboard. Use the manual UI steps below, or add and review that script separately before running it.

## 1. Prerequisites

- Docker Desktop (Windows/macOS) or Docker Engine + the Docker Compose plugin (Linux).
- A running Supabase/PostgreSQL project.
- The pipeline SQL scripts applied successfully, including the transformation tables and `insights_tables.sql` before setting up all Explain cards.
- Network access from the machine running Metabase to the PostgreSQL endpoint. For Supabase, prefer the **Session pooler** connection when your environment requires it; use the host/port/user shown in your own Supabase dashboard.

Check Docker is installed:

```sh
docker --version
docker compose version
```

## 2. Start Metabase

From this directory (`setup/metabase/`), run:

```sh
docker compose up -d
```

Open <http://localhost:3000>. First startup can take a few minutes. Complete the first-run wizard and create an administrator account. The Compose file persists Metabase's own application data in the `olist_metabase_data` Docker volume, so dashboards and settings survive container recreation.

Useful commands:

```sh
docker compose logs -f metabase
docker compose ps
docker compose down
```

`docker compose down` preserves the named volume. To remove the Metabase application database and all Metabase configuration, `docker compose down -v` will delete that volume; do not run it unless you intend to reset Metabase.

The Compose file uses the upstream `metabase/metabase:latest` image. For a controlled or production deployment, confirm compatibility and replace `latest` with an explicitly approved version tag before deploying. Back up the named volume before upgrades.

## 3. Create a read-only database login

Run this in the Supabase SQL Editor as a database administrator, adapting the password and role memberships to the grants used in your environment. The project materials expect the `analytics_reader` role to have read access to `analytics` and `ops.agent_logs` only. Confirm those grants exist before granting membership.

```sql
-- Replace the placeholder with a strong unique password; never commit it.
create role metabase_reader login password 'REPLACE_WITH_A_LONG_RANDOM_PASSWORD';
-- Only if analytics_reader already exists and has the intended read-only grants:
grant analytics_reader to metabase_reader;
```

If the role already exists, do not rerun `CREATE ROLE`; rotate or update credentials using your database's approved process. Verify access with a test query and verify that writes to pipeline schemas are denied. Do not connect Metabase using the Supabase service-role key or a database superuser.

For Supabase's Session pooler, the username often has the form `metabase_reader.<project-ref>`; use the exact username displayed by your project's connection instructions. Host, port, database, SSL requirements, and username format can vary by connection method and project, so do not copy example values blindly.

## 4. Add the database in Metabase

1. In Metabase, open **Admin settings → Databases → Add database** (labels may vary by version).
2. Choose **PostgreSQL**.
3. Enter the Supabase/PostgreSQL host, port, database name, username, and password from your project's connection details. For Supabase Session pooler, the port is commonly `5432`, but verify it in the dashboard.
4. Enable SSL if required by the endpoint/provider; use the provider's current connection instructions.
5. Save and use **Test connection**.
6. Ensure the database connection can see the `analytics` and `ops` schemas. Restrict visibility to these schemas where practical. Do not expose `raw`, `cleaning`, `clean`, or `models` schemas to dashboard users unless there is a specific approved reason.
7. Name the connection clearly, e.g. `Olist (Supabase)`. The name is user-defined and can be different in your environment.

If the connection fails, verify the host/port, pooler username suffix, password, SSL setting, network/firewall access, and role grants. Do not paste credentials into tickets or logs.

## 5. Confirm the expected tables

After collection, cleaning, transformation, and Explain have completed, confirm the following objects exist and have data where expected:

- Core KPI/trend tables: `analytics.kpi_summary`, `analytics.monthly_revenue`, `analytics.revenue_by_state`, `analytics.top_categories`.
- Explore/drill-down tables: `analytics.order_items_wide`, `analytics.orders_wide`, `analytics.order_facts`.
- Refresh status: `analytics.refresh_status`.
- Explain outputs (after Explain stage): `analytics.insight_summary`, `analytics.insight_causes`, `analytics.insight_recommendations`.
- Operational log: `ops.agent_logs`.

Names are taken from the included workflow and dashboard documentation; if your SQL scripts or workflow configuration have been modified, verify the actual table contracts before creating cards. Empty Explain tables are expected until the Explain workflow runs successfully.

## 6. Build the dashboard manually

The original project notes describe a dashboard called `Olist sales`, a collection called `Olist webinar`, and a second dashboard `Olist late deliveries · drill-down`. These names are suggestions from the design notes, not pre-created objects.

1. Create a collection named `Olist webinar` (or another team-approved name).
2. Create SQL questions against the configured PostgreSQL connection, using only the published schemas. For a simple connectivity test:

   ```sql
   select * from analytics.kpi_summary limit 10;
   ```

3. Add KPI number cards for revenue, orders, customers, average order value, and average review score from `analytics.kpi_summary`.
4. Add a monthly trend from `analytics.monthly_revenue`; use month as the X axis and revenue as the line series. If comparing orders too, use a visualization that supports a second series.
5. Add state and category breakdowns using `analytics.revenue_by_state` and `analytics.top_categories`.
6. Add Explain cards from `analytics.insight_summary`, `analytics.insight_causes`, and `analytics.insight_recommendations` only after the Explain workflow has populated them.
7. Add an activity/log card from `ops.agent_logs` with an appropriate row limit and sort by the timestamp column actually present in that table.
8. Save the dashboard as `Olist sales` if you want to match the supplied design notes. Add filters only after checking the real columns and field types. Test every filter and click behavior with known sample data.
9. Create the late-delivery drill-down dashboard only after verifying `analytics.order_facts` and the available filter columns. Treat click-through interactions as unverified until tested in your deployed Metabase version.

Do not assume every card or click behavior is automatically generated. The referenced dashboard-building Python script is missing from the supplied project artifacts.

## 7. End-to-end validation

- [ ] Metabase opens at `http://localhost:3000` and admin sign-in works.
- [ ] Metabase container restarts without losing dashboards/settings.
- [ ] Database connection test succeeds using the read-only login.
- [ ] The login can read approved `analytics` tables and `ops.agent_logs`, and cannot write to pipeline data.
- [ ] A test SQL question returns rows from `analytics.kpi_summary`.
- [ ] KPI values reconcile with transformation validation outputs.
- [ ] Explain cards populate after a successful Explain run.
- [ ] Dashboard filters, refresh behavior, and click-throughs have been tested with known records.
- [ ] A backup/restore approach for the Metabase volume and the PostgreSQL database is documented.

## Security notes

- Keep passwords out of source control and screenshots. Use a secrets manager or deployment environment variables for shared environments.
- Keep Metabase on a trusted network; do not expose port `3000` publicly without TLS, authentication, and network controls.
- Use a dedicated read-only database account with the minimum schema/table grants needed.
- Use separate development and production databases/connections. Review generated SQL before saving or sharing questions.
- Limit who can create native SQL questions or download data when working with customer-related datasets.
