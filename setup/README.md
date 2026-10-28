# Olist Data Analytics Pipeline — setup and import guide

This guide is based on the contents of the three supplied archives: `collection_workflow.zip`, `Cleaning_Transformation_Package.zip`, and `explain_phase.zip`. It distinguishes settings visible in the exported workflow JSON from values you must supply in your own environment.

> **Important scope note:** these ZIPs include collection, cleaning, transformation, and Explain workflows. They do **not** include a separate Week 3 orchestrator workflow JSON. The collection guide mentions a future orchestrator, but it is not part of the supplied artifacts. Run the stages in the sequence below unless your team supplies that orchestrator separately.

## A. Project overview

### Pipeline architecture

```text
Google Drive CSVs ─────┐
Google Sheets tabs ────┼─> Collection · Main + source loaders
Mock/real paginated API┘             │
                                     ▼
                            Supabase PostgreSQL
                         raw.* + ops.agent_logs
                                     │
                                     ▼
                              Cleaning · Main
                     profile → propose rules → dry run
                          → human approval if needed
                          → apply rules → clean.*
                                     │
                                     ▼
                            Transformation · Main
                       propose/reuse SQL → validate
                       → repair once if needed → publish
                           models.* → analytics.*
                                     │
                                     ▼
                              Explain · Main
                    aggregate KPI changes → AI explanation
                    → reconcile → stage → publish insights
                                     │
                                     ▼
                                   Metabase
                         dashboard + drill-down/insights
```

### Workflow responsibilities

| Workflow | Purpose | Trigger / relationship |
|---|---|---|
| `Mock API · Olist payments & reviews` | Serves paginated JSON for payments and reviews from Drive files through a webhook. | Must be published and reachable before the collection API loader can call it. |
| `Collection · Load CSV from Drive` | Downloads a CSV from Drive, parses rows, batches inserts into `raw.*`, and writes a log result. | Called by `Collection · Main` through Execute Sub-workflow. |
| `Collection · Load Sheet tab` | Reads a specific Google Sheets tab and inserts rows into the matching raw table. | Called by `Collection · Main`. |
| `Collection · Load API source` | Calls a paginated HTTP endpoint, splits returned records, maps source fields, preserves raw records, and inserts into a raw API table. | Called by `Collection · Main`; its endpoint is the mock API by default. |
| `Collection · Main` | Iterates over nine source definitions, dispatches to the correct loader, profiles raw columns, asks an Anthropic model for data contracts and cross-source mismatch summaries, and logs results. | Run manually first. Its `Sources` Code node contains source IDs and test controls. |
| `Cleaning · Approve rules` | Displays pending cleaning rules in an n8n form and records human decisions; posts to the wait-resume URL when submitted. | Used when `Cleaning · Main` has risky rules awaiting approval. |
| `Cleaning · Main` | Copies each raw source into `cleaning.*`, profiles it, reuses or proposes cleaning rules with Gemini, dry-runs rules, requests approval where required, applies accepted rules transactionally, and writes typed `clean.*` tables plus logs/quarantine. | Run after collection. |
| `Transformation · Main` | Builds one view per configured business question. Reuses previously passed SQL unless fresh SQL is requested, validates generated SQL against guardrails and reference checks, tries a repair if needed, and publishes tables into `analytics.*` transactionally. | Run after cleaning. A Schedule Trigger is configured for 02:00 but should be enabled only after manual tests. |
| `Explain · Main` | Refreshes order-level facts, detects KPI/month changes, calculates aggregate breakdowns, asks Gemini to explain movements and propose actions, checks reconciliation, and stages/publishes insights. | Run after transformation and after `insights_tables.sql` has been installed. |
| Metabase dashboard | Reads the published analytics and insights tables for KPI tiles, trends, breakdowns, activity/logs, insight summaries, and drill-downs. | Configure after the database tables exist; dashboard guide notes some click-through behaviors have not yet been tested against the target Metabase version. |

### Data stages

1. **Collection:** source values are intentionally retained as messy strings. The raw layer is not the place to normalize dates, numbers, blank rows, or repeated headers.
2. **Cleaning:** a working copy is profiled; rules are generated or reused; dry-run checks show impact; risky rules can wait for a person; rules are applied to typed `clean.*` tables.
3. **Transformation:** defined business rules identify counted orders, revenue, customers, and other metrics. SQL views are validated before they are published to `analytics.*`.
4. **Explain:** KPI settings in `insights.kpi_config` determine what is monitored. Aggregated data—not raw customer records—is sent to the model. The workflow stages and reconciles results before publishing.
5. **Dashboard:** Metabase reads published analytics/insights. It may cache query results, so refresh after a successful run.

The cleaning and transformation guides document saved-rule/SQL reuse to reduce model calls. To force new proposals for a demonstration, use the explicit `FRESH_RULES` or `FRESH_SQL` controls described below; do not leave them enabled casually in a scheduled production run.

## Dataset policy and the `data/` folder

**No dataset is bundled with this project ZIP, and you do not need to upload a dataset to receive or use the setup package.** The top-level `data/` directory is intentionally empty so your team can place data there later if desired. The exported collection workflows are configured around Google Drive CSV files, Google Sheets tabs, and a paginated HTTP API (the included mock API workflow uses Drive-backed JSON files); they do not automatically read files merely because they are placed in `data/`. If you choose to store source files locally, update the relevant collection workflow nodes and credentials to read those local files, or keep the current Drive/Sheets/API source configuration and place the files in those services instead.

**Metabase setup instructions are included** in `setup/metabase/README.md`, with dashboard/table guidance in `setup/metabase/DASHBOARD.md` and a Docker Compose file for a local Metabase instance. Follow those instructions after the analytics database objects exist; dashboard cards that depend on Explain outputs will remain empty until that workflow has run successfully. The dashboard builder script referenced in the original project notes was not supplied, so the package documents manual dashboard setup rather than claiming automated dashboard creation.

## B. Prerequisites

### Accounts and access

- [ ] n8n Cloud account or a self-hosted n8n instance. The collection guide documents a local n8n `2.42.7` setup, but the exports do not pin an immutable build.
- [ ] Supabase project with PostgreSQL access and sufficient storage for raw + working + clean + analytics data.
- [ ] Google account that can access the five CSV files and spreadsheet.
- [ ] Google Cloud project with Google Drive API and Google Sheets API enabled if configuring self-hosted Google OAuth.
- [ ] Anthropic API account/key for the collection workflow.
- [ ] Google Gemini API account/key for cleaning, transformation, and Explain.
- [ ] Metabase instance (local or hosted) that can connect to Supabase PostgreSQL.
- [ ] Permission to create schemas/tables/functions and to configure roles/grants, or a database administrator who can execute/adapt the SQL scripts.
- [ ] Source data: five CSV files, one spreadsheet with two tabs, and payments/reviews JSON files for the mock API.

### Software and dependencies

- No Python package installation is established by the supplied ZIPs. There are no Python source files or Python dependency manifests in the three archives. n8n Code nodes use JavaScript.
- No separate npm package dependency list is included. Use a supported n8n release that provides the node types present in the exports.
- PostgreSQL SQL functions, JSONB, PL/pgSQL, roles/grants, and transactions are used. Supabase PostgreSQL is the documented target.
- The supplied SQL does not create a PostgreSQL extension.
- The cleaning package explicitly documents PostgreSQL 15+ (or Supabase PostgreSQL). The minimum Metabase version is not specified; confirm compatibility with the version you deploy.

### Expected source files and data contracts

The collection guide lists these nine inputs. File sizes/counts are approximate and depend on the dataset revision.

| Logical source | Input location/type | Raw destination |
|---|---|---|
| `orders` | `orders.csv` in Drive | `raw.orders_csv` |
| `order_items` | `order_items.csv` in Drive | `raw.order_items_csv` |
| `customers` | `customers.csv` in Drive | `raw.customers_csv` |
| `sellers` | `sellers.csv` in Drive | `raw.sellers_csv` |
| `geolocation` | `geolocation.csv` in Drive | `raw.geolocation_csv` |
| `products` | Google Sheets tab `products` | `raw.products_sheet` |
| `category_translation` | Google Sheets tab `category_translation` | `raw.category_translation_sheet` |
| `payments` | Paginated API response from mock API | `raw.payments_api` |
| `reviews` | Paginated API response from mock API | `raw.reviews_api` |

CSV headers and sheet columns must match the raw table contract. Keep source values as text during ingestion; preserve leading zeros, decimal commas, mixed date formats, blank rows, and repeated headers. The API loader maps selected fields into stable raw columns and keeps the original JSON record in `raw_record` where the raw SQL defines it. Do not put `answer_key.csv` in a Drive folder used by the workflow.

## Metabase setup files

A dedicated self-hosted Metabase guide and Docker Compose file are included in `setup/metabase/`. Follow `setup/metabase/README.md` to start Metabase, connect it to Supabase/PostgreSQL with a read-only account, and create/validate dashboard cards. The supplied archives refer to a dashboard builder script and a Windows start script, but those scripts were not present in the supplied files; dashboard automation is therefore not included or assumed.

## C. External service setup

### 1. Create Supabase and install database objects

1. Create a Supabase project and save its database password securely.
2. In the Supabase SQL Editor, run the SQL scripts in this order:
   1. `Cleaning_Transformation_Package/sql/01_raw_tables.sql`
   2. `Cleaning_Transformation_Package/sql/02_ops_tables.sql`
   3. `Cleaning_Transformation_Package/sql/03_clean_tables.sql`
   4. `Cleaning_Transformation_Package/sql/04_transform_tables.sql`
   5. `explain_phase/scripts/insights_tables.sql`
3. These scripts are in separate supplied ZIPs. Extract them locally for execution; they are not included in the final setup package.
4. Do **not** run both raw table scripts as separate competing definitions. `collection_workflow/scripts/raw_tables.sql` overlaps with the cleaning package's `01_raw_tables.sql`; use the cleaning package version for the complete setup.
5. Use the cleaning package's `02_ops_tables.sql` rather than the collection-only `ops_tables.sql`, because the cleaning version adds the `profile` column to `ops.data_contracts`.
6. Read `04_transform_tables.sql` before execution. It includes role/grant operations for `transform_agent` and `analytics_reader`. Confirm your Supabase database role can create roles/grant privileges; if Supabase restricts a statement, have an administrator adapt it to the least-privilege equivalent rather than granting broad owner privileges to AI or BI accounts.
7. Confirm that the expected schemas exist: `raw`, `ops`, `cleaning`, `clean`, `models`, `transform`, `analytics`, and `insights`.
8. Run a small query such as `select table_schema, table_name from information_schema.tables where table_schema in ('raw','ops','clean','analytics','insights') order by 1,2;` to confirm installation.

**Database connection values:** in Supabase, open the project’s **Connect** dialog / database connection settings and select the session pooler connection details recommended for your environment. The supplied collection guide recommends the session pooler rather than the direct connection because direct connections may require IPv6. Typical fields are host, database (`postgres`), username (pooler username may include the project reference), password, port, and SSL. Copy the actual values from your project; never use a sample host or password from a guide.

**Storage:** geolocation alone is approximately one million rows. Check your Supabase plan/database storage before the full run. The pipeline keeps raw and cleaned copies and creates working/staging data, so required capacity is larger than the raw files alone.

### 2. Prepare Google Drive and Sheets

**Drive CSV folder**
1. Create a dedicated folder, e.g. `olist-raw-csv`.
2. Upload only the five source CSVs: `orders.csv`, `order_items.csv`, `customers.csv`, `sellers.csv`, and `geolocation.csv`.
3. Ensure uploads remain files rather than being converted to Google Sheets. Do not upload `answer_key.csv`.
4. Copy each file ID from its Drive URL/details; you will paste it into the `Sources` Code node.

**Google spreadsheet**
1. Create a spreadsheet, e.g. `Olist product list`.
2. Create tabs named exactly `products` and `category_translation`.
3. Import each source into its matching tab. During import, do not convert text to numbers, dates, or formulas; check that ZIP prefixes and decimal-comma values remain text as intended.
4. Copy the spreadsheet ID from the URL. The ID is not the tab name.

**Google Cloud OAuth for self-hosted n8n**
1. Open Google Cloud Console and create/select a project.
2. Enable **Google Drive API** and **Google Sheets API**.
3. Configure the OAuth consent screen and add the account(s) that will authorize the integration as test users if the app remains in testing mode.
4. Create an OAuth Client ID of the type required by your n8n credential screen. Copy the exact redirect URI displayed by n8n into the Google Cloud client configuration.
5. Store the client ID and client secret securely and complete the sign-in flow from n8n.
6. For n8n Cloud, use the credential creation flow supported by the hosted instance; the self-hosted OAuth client steps may not apply.

### 3. Configure the mock API source

The included `Mock API · Olist payments & reviews` workflow uses a webhook path `olist-mock-api`, downloads JSON files from Google Drive, parses the JSON, and returns one page per request.

1. Upload `payments.json` and `reviews.json` to a separate Drive folder.
2. Import the mock API workflow and connect its Google Drive credential.
3. Open its `Pick file` Code node and verify the configured mapping from `source` query parameter to the correct Drive file ID. The export uses placeholders/environment-specific values that must be checked after import.
4. Publish the workflow so the production webhook URL is available.
5. Test the webhook and confirm a JSON response with pagination metadata (`page`, `total_pages`) and a page of records (`data` as expected by the loader).
6. Open `Collection · Main` → `Sources` and replace `MOCK_API_URL` with the production webhook URL reachable **from the n8n server/container**. The exported default is `http://localhost:5678/webhook/olist-mock-api`; it will not work unchanged if n8n runs in a different container, host, or cloud service.
7. The API loader paginates with a maximum of 50 requests. Confirm the response's page numbering and total-page field match the loader's completion expression. If you adapt a real API, update authentication, pagination, response parsing, and rate-limit behavior accordingly.

### 4. Configure Anthropic and Gemini

1. In n8n Credentials, create the Anthropic credential supported by the Anthropic Chat Model node. Use an API key from your Anthropic account.
2. Create the Google Gemini credential supported by the Google Gemini Chat Model node. Use a key from the appropriate Google AI provider console.
3. Confirm that your account can use the exported model IDs:
   - Anthropic: `claude-sonnet-5-5` (collection contract/mismatch agents).
   - Gemini: `models/gemini-2.5-flash` (cleaning, transformation, Explain, and repair agents).
4. These exact IDs are visible in the exports, but the ZIP cannot guarantee they remain available to all accounts or node versions. If a model is unavailable, choose an approved currently supported model and document the change consistently in every corresponding model node.
5. Configure billing limits/quotas and monitor usage before the first full dataset run. Cleaning and transformation can reuse stored rules/SQL, but fresh modes invoke the models again.

### 5. Configure Metabase

1. Start or provision Metabase using a version compatible with your environment. The supplied dashboard guide does not pin a version.
2. Create a dedicated read-only database role for Metabase. The SQL references `analytics_reader`; the dashboard guide also discusses a `metabase_reader` login. Confirm which role is actually created and use the intended one. Do not use the n8n write credential.
3. If using Supabase's pooler, check the username format required by the pooler. The dashboard guide specifically notes that a `metabase_reader` login may need `metabase_reader.<project-ref>`.
4. In Metabase, add a PostgreSQL database connection using the Supabase host, database, port, SSL, username, and password.
5. Verify Metabase can read `analytics.kpi_summary`, `analytics.monthly_revenue`, `analytics.revenue_by_state`, `analytics.top_categories`, `analytics.orders_wide`, `analytics.order_items_wide`, and the Explain insight tables after their workflows run.
6. Follow `explain_phase/metabase/DASHBOARD.md` for dashboard creation. Its accompanying `dashboard.env.example` lists `MB_URL`, `MB_ADMIN_EMAIL`, `MB_ADMIN_PASSWORD`, optional `MB_DATABASE`, and `PG_HOST`, `PG_PORT`, `PG_DB`, `PG_USER`, `PG_PASSWORD`; fill a private environment file and never commit secrets. **The referenced `scripts/build_metabase_dashboard.py` is not present in the supplied ZIPs**, so that automation cannot be run from these artifacts alone. Build the dashboard manually from the guide or obtain the missing script from the project owner.
7. Refresh Metabase after pipeline runs; cached results may briefly appear stale. Insight cards will remain empty until `Explain · Main` has successfully run.

## D. n8n credentials and configuration

### Credential inventory by workflow/node

The exports have empty/missing `credentials` blocks on the inspected nodes. This means credential names are **not embedded** and credentials will need to be assigned after import.

| Workflow | Nodes requiring credential selection | Credential type |
|---|---|---|
| `Collection · Main` | `Contract model`, `Mismatch model` | Anthropic Chat Model / Anthropic API |
| `Collection · Main` | All `Postgres` nodes, including `Log failure`, `Profile columns`, `Sample rows`, `Save data contract`, `Cross-source checks`, `Save mismatch report`, `Log run` | Postgres |
| `Collection · Load CSV from Drive` | `Download CSV from Drive` | Google Drive OAuth2 |
| `Collection · Load CSV from Drive` | `Truncate raw table`, `Insert into raw table`, `Write agent log` | Postgres |
| `Collection · Load Sheet tab` | `Read sheet tab` | Google Sheets OAuth2 |
| `Collection · Load Sheet tab` | `Truncate raw table`, `Insert into raw table`, `Write agent log` | Postgres |
| `Collection · Load API source` | `Call API (all pages)` | HTTP Request; no auth is configured for the included mock endpoint |
| `Collection · Load API source` | `Truncate raw table`, `Insert into raw table`, `Write agent log` | Postgres |
| `Mock API · Olist payments & reviews` | `Download JSON from Drive` | Google Drive OAuth2 |
| `Cleaning · Approve rules` | `Get pending rules`, `Save decisions`, `Log approval` | Postgres |
| `Cleaning · Approve rules` | `Continue cleaning run` | HTTP Request to a generated n8n resume URL; no external auth credential is shown |
| `Cleaning · Main` | All Postgres nodes (profiling, rule storage, dry run, application, checks, logging) | Postgres |
| `Cleaning · Main` | `Cleaning model`, plus any repair model node present in the flow | Google Gemini |
| `Transformation · Main` | All Postgres nodes (schema, stored SQL, validation, publish, logs) | Postgres |
| `Transformation · Main` | `Transformation model`, `Repair model` | Google Gemini |
| `Explain · Main` | All Postgres nodes (order facts, breakdowns, staged/final writes, logs) | Postgres |
| `Explain · Main` | `Explain model`, `Repair model` | Google Gemini |

### Configure each credential

**Postgres / Supabase**
- In n8n, create a Postgres credential.
- Use the exact connection details from Supabase's session pooler (or another connection method approved for your deployment): host, database, username, password, port, SSL mode.
- The collection guide's suggested label is `Supabase`; the name is not technically required.
- Test the credential, then assign it to every Postgres node across all imported workflows.
- The connected role needs the permissions required by the SQL scripts. Avoid broad superuser/owner access if separate roles can safely be used.

**Google Drive**
- Create/authorize the Google Drive credential in n8n.
- For self-hosted OAuth, use the Google Cloud OAuth client and redirect URI described in section C.
- Assign it to `Download CSV from Drive` and `Download JSON from Drive`.
- Confirm the authorized Google account can read each source file.

**Google Sheets**
- Create/authorize the Google Sheets credential in n8n.
- Assign it to `Read sheet tab`.
- Confirm access to the spreadsheet and exact tabs `products` and `category_translation`.

**Anthropic**
- Create the Anthropic credential and enter the API key in n8n's credential UI.
- Assign it to `Contract model` and `Mismatch model` in `Collection · Main`.
- Confirm the selected model ID is available to your API account.

**Google Gemini**
- Create the Gemini credential and enter the API key in n8n's credential UI.
- Assign it to all Gemini model nodes in Cleaning, Transformation, and Explain, including repair model nodes.
- Confirm quota and model availability.

**HTTP Request**
- The collection API request calls the configured mock API URL without an auth scheme in the export. The approval workflow posts to a URL produced by the wait/resume interaction.
- Do not add credentials to the mock API unless you deliberately secure the endpoint and update both sides. For a real external API, use the authentication method required by that provider and avoid putting tokens directly in Code-node strings.

## E. Exact workflow import order

Import the JSON files from the source ZIPs in the following order. The order respects Execute Sub-workflow dependencies and the downstream data dependency chain.

1. **`mock_api.json` — `Mock API · Olist payments & reviews`**
   - **Why now:** the collection API loader expects a reachable HTTP endpoint. This is an HTTP dependency, not an Execute Sub-workflow reference.
   - **Depends on:** Google Drive access to payments/reviews JSON and the configured file-ID mapping in `Pick file`.
   - **Credentials:** Google Drive.
   - **After import:** configure the file IDs, connect Drive, inspect the webhook path `olist-mock-api`, publish it, and copy the production URL into the collection `Sources` node. Do not use the test URL for normal execution.

2. **`collect_load_csv.json` — `Collection · Load CSV from Drive`**
   - **Why now:** this child workflow must exist before `Collection · Main` calls it.
   - **Depends on:** Supabase raw tables and source Drive files.
   - **Credentials:** Postgres, Google Drive.
   - **After import:** assign credentials and verify the Execute Workflow Trigger accepts incoming data. It expects `table`, `file_id`, `run_id`, and batch/source metadata from its parent. It is not intended to be run directly without input.

3. **`collect_load_sheet.json` — `Collection · Load Sheet tab`**
   - **Why now:** child workflow called by the collection parent.
   - **Depends on:** Supabase raw tables and spreadsheet tabs.
   - **Credentials:** Postgres, Google Sheets.
   - **After import:** assign credentials and verify sheet ID/tab arrive from the parent. Keep the sheet tab names exact.

4. **`collect_load_api.json` — `Collection · Load API source`**
   - **Why now:** child workflow called by the collection parent.
   - **Depends on:** Supabase raw tables and a reachable paginated API endpoint.
   - **Credentials:** Postgres; HTTP Request has no auth configured for the mock endpoint.
   - **After import:** assign Postgres, verify the request URL is supplied by the parent, and confirm response pagination fields (`page`, `total_pages`, `data`) match the loader logic.

5. **`collection_main.json` — `Collection · Main`**
   - **Why now:** its Execute Workflow nodes refer to the three child workflow IDs (`olistLoadCsv0001`, `olistLoadSht0001`, `olistLoadApi0001`), so import children first.
   - **Depends on:** all three loaders, the published mock API endpoint, raw/ops tables, Google sources.
   - **Credentials:** Postgres and Anthropic.
   - **After import:** open `Sources`; replace the five Drive `PASTE_ID` placeholders, `SPREADSHEET_ID`, and `MOCK_API_URL`; optionally set `ONLY` to a small source list. Inspect each Execute Sub-workflow node and reselect the matching child workflow if the imported IDs differ. Keep “wait for sub-workflow completion” enabled. Connect credentials.

6. **`1_cleaning_approval.json` — `Cleaning · Approve rules`**
   - **Why now:** it must be available before cleaning runs that need human review.
   - **Depends on:** `ops.cleaning_rules`, `ops.cleaning_approvals`, `ops.agent_logs`, and the approval/wait resume interaction from Cleaning Main.
   - **Credentials:** Postgres; HTTP Request posts to the resume URL generated by the workflow.
   - **After import:** assign Postgres, check the form trigger and published/form URL behavior for your n8n version, and verify the resume URL is passed through without being hard-coded. Keep the approval form access appropriately restricted.

7. **`2_cleaning_main.json` — `Cleaning · Main`**
   - **Why now:** consumes `raw.*` and `ops.data_contracts` produced by collection and uses the approval workflow when required.
   - **Depends on:** raw/ops/cleaning SQL objects, Collection stage output, approval workflow.
   - **Credentials:** Postgres and Gemini.
   - **After import:** assign credentials to every Postgres and Gemini node; inspect `Tables` for `ONLY`, `FRESH_RULES`, and `APPROVAL_FORM_URL`; confirm form URL/resume behavior. Run only a small table first.

8. **`3_transformation_main.json` — `Transformation · Main`**
   - **Why now:** consumes the typed `clean.*` schema created by Cleaning Main.
   - **Depends on:** `clean.*`, transformation functions/tables/roles from `04_transform_tables.sql`, successful cleaning.
   - **Credentials:** Postgres and Gemini.
   - **After import:** assign credentials, inspect `Questions` for `ONLY` and `FRESH_SQL`, verify `transform_agent` permissions, and leave the nightly trigger disabled until manual tests pass.

9. **`explain_main.json` — `Explain · Main`**
   - **Why last:** depends on the transformed order-level analytics data and insight tables/configuration.
   - **Depends on:** successful Transformation Main; `explain_phase/scripts/insights_tables.sql`; enabled rows in `insights.kpi_config`; compatible permissions.
   - **Credentials:** Postgres and Gemini.
   - **After import:** assign credentials, inspect `Settings` (`MONTHS`, `KPIS`), check KPI config and any SQL/dashboard helper routines, and run after transformation. Explain docs state that real Gemini output and Metabase click-through have not yet been fully verified.

### Import mechanics and references

1. Extract the source ZIP locally.
2. In n8n, use **Import from File** for each JSON in the order above.
3. Save after each workflow is imported and configured.
4. Workflow IDs in exports are `olistMockApi0001`, `olistLoadCsv0001`, `olistLoadSht0001`, `olistLoadApi0001`, `olistCollMain001`, `olistCleanAppr01`, `olistCleanMain01`, `olistTransMain01`, and `olistExplMain01`. These are export IDs; an import into another n8n instance may assign different internal IDs.
5. In `Collection · Main`, verify all three Execute Workflow nodes by selecting the child workflow from the current instance's workflow list. Do not rely on a copied ID alone.
6. There is no separate orchestrator JSON in the supplied files. Do not invent an orchestrator workflow ID or assume it was imported.

## F. Post-import configuration

Complete this checklist before running the pipeline:

1. **Credentials:** assign Postgres, Drive, Sheets, Anthropic, and Gemini credentials to all nodes listed in section D. Exports do not retain secrets or credential bindings.
2. **Sub-workflow references:** in `Collection · Main`, reselect the CSV, Sheets, and API loader workflows if their references do not resolve. Ensure waiting for child completion is enabled.
3. **Drive file IDs:** replace each `PASTE_ID` under `Sources` → `DRIVE_FILE_IDS` with the actual file ID for the matching CSV.
4. **Spreadsheet ID:** replace `SPREADSHEET_ID`; verify `products` and `category_translation` tab names.
5. **Mock API URL:** set `MOCK_API_URL` to the published webhook's production URL accessible from the n8n runtime. If n8n is in Docker, `localhost` inside the container refers to that container, not the host computer.
6. **Mock API source mapping:** verify the `Pick file` node maps `payments` and `reviews` to the correct JSON Drive file IDs and that returned pages have the expected shape.
7. **Database:** confirm schema/table names and roles match the SQL scripts; run a select query against `raw.*` and inspect the actual `clean.*` / `analytics.*` schema after each stage.
8. **LLM models:** verify the exact model IDs are available to the connected accounts; use a supported replacement only as a deliberate documented change.
9. **Approval URL:** verify the form trigger and `APPROVAL_FORM_URL` configuration in Cleaning Main; test that submitting decisions resumes the waiting execution.
10. **Metabase:** configure the read-only database connection and dashboard environment variables from the included template; refresh the schema after creating the insight tables.
11. **Save:** save each workflow. Keep all scheduled triggers and production publishing disabled until individual manual tests pass.

## G. Step-by-step execution and testing

Use a development database or a fresh test project first. The collection loader truncates each raw destination before reloading it; running a source loader can replace existing raw data.

### Test 0 — database schema smoke test

**Input:** SQL scripts installed.

**Checks:**
- Expected schemas/tables exist in `information_schema`.
- `ops.agent_logs` and `ops.data_contracts` exist with columns required by the workflows.
- `cleaning` helper functions and transformation validation/publishing functions exist.
- Role/grant statements succeeded, and the n8n credential can connect with the required access.

**Success:** no missing schema/table/function/role errors in a simple read query. Do not proceed if SQL installation partially failed.

### Test 1 — mock API

**Input:** `payments.json` and `reviews.json` available in Drive; mock workflow credentials set.

1. Publish `Mock API · Olist payments & reviews`.
2. Call its production URL with a supported `source` and `page=1`.
3. Check HTTP status, JSON parseability, expected source name, current page, total pages, and a records array.
4. Test the final page and an invalid/empty source behavior if the workflow defines it.

**Success:** each request returns the page structure the loader expects and does not exceed reasonable response size/time. If using remote n8n, test from the n8n runtime's network path.

### Test 2 — source loader(s) and collection

Start with a small source such as `sellers` or `category_translation`. Set `ONLY` in `Collection · Main` to the one source and use the correct IDs.

**Expected inputs:** parent sends `source`, `type`, `table`, `run_id`, `batch_size`, and source-specific IDs/URL.

**Expected outputs:** loader returns one summary item containing status, `rows_read`, `rows_written`, duration, table, type, label, and failure state; raw table contains the rows plus `_run_id`/load timestamp fields where defined.

**Checks:**
- `rows_read` and `rows_written` are consistent.
- `raw.*` columns match the actual incoming headers and raw SQL.
- No numeric/date normalization occurred during collection.
- `ops.agent_logs` has success/failure records.
- A second run replaces the raw table contents instead of duplicating them, because the loader truncates first.

Then test each source type separately (CSV, Sheets, API). Before full load, check Drive/Sheet IDs and API page counts. Run all nine sources only after the small tests pass. Geolocation uses a batch size of 5,000; the other default batch size is 2,000.

### Test 3 — collection contracts and mismatch report

**Input:** raw tables populated.

Run `Collection · Main` after all source loaders pass.

**Checks:**
- `ops.data_contracts` contains contract rows per source.
- A cross-source mismatch report is saved (the export uses source `_cross_source`).
- `ops.agent_logs` includes run and agent activity.
- Review model output for plausible types, keys, and relationships; treat AI suggestions as proposals, not as proof of correctness.

**Success:** no source failures, contracts saved, and mismatch checks are inspectable. If the model fails, inspect n8n execution logs and provider quota/model settings.

### Test 4 — cleaning on a single table

Set `ONLY` in Cleaning Main's `Tables` Code node to a small source such as `sellers`, keep `FRESH_RULES = false` for normal repeatable testing, and run the workflow.

**Expected behavior:** working copy created under `cleaning.*`, columns/whole-table profiled, contract fetched, rules reused or proposed, rules dry-run, rule/log rows saved, and a typed `clean.*` table checked.

**Checks:**
- Inspect profile counts and dry-run examples before accepting risky changes.
- Confirm proposed rules have valid status/target/source and SQL checks pass.
- If approval is required, use `Cleaning · Approve rules`; review the proposed rules, choose decisions, submit, and confirm the waiting execution resumes.
- Undecided rules time out after two hours and are expired/rejected by the workflow. Do not leave a test approval hanging if you expect a deterministic run.
- Confirm `ops.cleaning_rules`, `ops.cleaning_approvals`, `ops.quarantine`, and `ops.agent_logs` show the expected run activity.
- Confirm raw tables remain unchanged and output types in `clean.*` match `sql/03_clean_tables.sql`.

Then run all cleaning tables. Geolocation is the slowest stage; its profile uses a sample when tables exceed 200,000 rows. If you reject an invalid date rule, invalid dates may become NULL by design; validate this impact rather than assuming all rows will retain a date.

### Test 5 — transformation on one view

Set `ONLY` in Transformation Main's `Questions` Code node to `['kpi_summary']` (or another exact configured view name), keep `FRESH_SQL = false` unless intentionally testing model generation, and run.

**Checks:**
- Agent SQL references only the live `clean.*` schema.
- SQL validation and reference reconciliation pass.
- `ops.transform_models` records a passed attempt and check details.
- The view appears in `models.*`; publish stage creates/replaces the corresponding `analytics.*` table only after validation.
- On failed first attempt, verify the repair attempt is logged; if both fail, the workflow should stop without publishing partial new analytics tables.
- Check business definitions: counted orders exclude null, `canceled`, and `unavailable` status and require at least one item; revenue sums price + freight for counted orders.

Then run all questions and verify `analytics.orders_wide`, `analytics.order_items_wide`, `analytics.kpi_summary`, `analytics.monthly_revenue`, `analytics.revenue_by_state`, and `analytics.top_categories`.

### Test 6 — Explain insights

**Prerequisites:** transformation tables exist, `insights_tables.sql` ran, `insights.kpi_config` contains at least one enabled KPI, Gemini credential works.

1. Set `MONTHS` to one known month (e.g. `['2018-03']`) if you want a limited test; leave empty for all months with a detected movement.
2. Optionally set `KPIS` to a configured KPI ID; leave empty to use enabled KPIs.
3. Execute Explain Main manually.
4. Check `analytics.order_facts` refresh, month/breakdown calculations, AI structured output, reconciliation checks, staged rows, and final published rows.
5. Inspect `analytics.insight_summary`, `analytics.insight_causes`, and `analytics.insight_recommendations`, plus `ops.agent_logs`.
6. If reconciliation fails, inspect the failed checks and do not bypass the guard. Review `insights.kpi_config` approved columns, gap condition, thresholds, pairs, and levers.

**Success:** run passes reconciliation and the published insight rows reflect the configured KPI/months. The included Explain documentation notes that real Gemini responses have not been validated by the authors in the supplied artifacts, so treat your first run as an integration test.

### Test 7 — Metabase and end-to-end

1. Connect Metabase using a read-only role.
2. Sync/refresh the database schema after transformation and Explain objects are created.
3. Open the dashboard and check data-as-of/refresh status, KPI tiles, monthly trends, state/category breakdowns, insights, and activity logs.
4. Compare KPI totals to direct SQL queries against `analytics.*`; ensure monthly totals exclude orders without purchase dates where the transformation contract says they should.
5. Refresh the dashboard after each pipeline run to avoid confusing cache lag with stale pipeline data.
6. Test month and cause click-throughs. The included dashboard guide says these click behaviors have not yet been tested in the target Metabase version; configure them manually if needed.

### End-to-end acceptance criteria

- [ ] All nine sources loaded and row counts/logs make sense.
- [ ] Raw source values remain preserved as received.
- [ ] Contracts/mismatch report saved and reviewed.
- [ ] Cleaning rules are auditable; risky rules received explicit human decisions or timed out according to policy.
- [ ] Clean table checks have no unexplained failures.
- [ ] Transform views pass validation and reference reconciliation.
- [ ] Failed transformation runs do not publish partial results.
- [ ] Explain outputs pass reconciliation and are published from staging.
- [ ] Metabase totals agree with SQL checks and show current data.
- [ ] No secret values are stored in workflow code or committed files.

## H. Troubleshooting

| Symptom | Likely cause | Practical resolution |
|---|---|---|
| Missing credentials after import | Workflow exports do not embed credential assignments. | Open each credential-using node and select the correct Postgres, Drive, Sheets, Anthropic, or Gemini credential; save and test. |
| Postgres connection refused / timeout | Wrong host/port, direct endpoint inaccessible, SSL mismatch, IP/network restriction. | Copy current connection details from Supabase; try the session pooler recommended by the project guide; require SSL; check n8n host/network reachability. |
| “Tenant or user not found” from pooler | Pooler username missing project-reference suffix. | Use the exact pooler username shown by Supabase; the dashboard guide calls out `metabase_reader.<project-ref>` for that named user. |
| Permission denied for schema/table/function | SQL roles/grants not installed or n8n is using a restricted role. | Inspect the SQL script and role grants; have an admin apply the intended least-privilege grants. Do not grant database owner/superuser to the AI role as a shortcut. |
| Relation/table/column does not exist | SQL scripts run out of order, wrong schema/table, or scripts from the overlapping packages were mixed. | Install `01_raw` → `02_ops` → `03_clean` → `04_transform` → Explain SQL. Use the cleaning package's raw/ops scripts as the consistent baseline. Compare node table names with `information_schema`. |
| “Workflow does not exist” in Execute Workflow | Child workflow ID changed on import. | In `Collection · Main`, choose the current child workflow from the list for each Execute Workflow node; verify waiting for completion remains enabled. |
| Loader runs alone and fails | Execute Workflow Trigger expects input from parent. | Run `Collection · Main` with `ONLY` set to the desired source, or provide the full expected input object in a deliberate test. |
| Google Drive download fails | Wrong file ID, file not shared with authorized account, OAuth consent not completed, Drive API disabled. | Verify ID and permissions; reauthorize credential; enable Drive API; use the correct Google account. |
| Google Sheets returns empty data / wrong columns | Spreadsheet ID/tab typo, missing access, unexpected header row or sheet import conversion. | Verify spreadsheet ID and exact tab names; share with OAuth account; inspect formatted values and headers. |
| API request fails / no rows | Mock API not published, URL unreachable from n8n, wrong `source`, bad pagination response, request cap reached. | Test production webhook; correct `MOCK_API_URL`; verify `page`, `total_pages`, and `data`; check network/Docker hostname and provider timeouts. |
| Webhook works in editor but not in loader | Test URL used instead of production URL or workflow not published. | Publish mock API and use `/webhook/olist-mock-api`, not `/webhook-test/…`, in normal runs. |
| LLM authentication/model error | Invalid API key, unavailable model ID, quota/billing issue, provider outage. | Test credential, verify current model catalog/access, check billing/quota, reduce test scope with `ONLY`, and retry after fixing the provider-side issue. |
| Structured output parser fails | Model output doesn't match expected schema or was truncated. | Inspect node output and execution logs; confirm model is supported; consider token/output settings only after understanding the expected structure. |
| Approval form never resumes | Form URL mismatch, wrong instance URL, workflow wait expired, or resume URL not passed correctly. | Check Cleaning Main's `APPROVAL_FORM_URL`, Form Trigger URL, execution wait node, and the approval workflow's `resume_url` input. Submit within the two-hour wait window. |
| Rejected/expired cleaning rule produces NULLs | This is deliberate behavior for invalid values when a rule is not approved. | Review rule effects and quarantine/log records; accept this only if it matches the team's data policy. |
| Transformation SQL rejected | SQL guardrail, schema mismatch, wrong output columns/grain, or reference reconciliation mismatch. | Inspect validation/check results and `ops.transform_models`; verify clean schema and business definitions. Do not bypass validation to force publish. |
| Empty Metabase dashboard | Transform/Explain not run, wrong database/schema permissions, no enabled KPI config, or dashboard schema not refreshed. | Check `analytics.*` row counts, `insights.kpi_config`, read-only role grants, and Metabase schema sync. Run Explain for insight cards. |
| Dashboard appears stale after a successful run | Metabase query caching. | Refresh the dashboard and check the Data as of / refresh status card. |
| Accented text is corrupted | Source was read with the wrong encoding. | Keep CSV data UTF-8; avoid opening/resaving through software that rewrites encoding. |
| Row counts differ from source | Empty rows/repeated headers are intentionally retained; Sheets conversion or batch errors can also affect counts. | Compare source and raw counts, inspect execution errors and `ops.agent_logs`, and ensure Drive/Sheets preserved raw values. |

## I. Security and best practices

1. **Never commit secrets.** Store database passwords, OAuth client secrets, Anthropic/Gemini API keys, Metabase API keys, and private environment values in n8n credentials or a secret manager. Keep `.env` files private.
2. **Least privilege:** use separate identities for n8n writes and Metabase reads. Limit Drive/Sheets access to source files. Avoid granting AI nodes unrestricted database owner privileges.
3. **Protect the answer key:** never upload `answer_key.csv` to a folder loaded by the collection workflow; it contains expected planted issues and is intended for private validation.
4. **Test on a development database:** loaders truncate target raw tables before reload; cleaning and transformation also rebuild working/published objects. Do not test against a shared production database without backups and explicit approval.
5. **Back up first:** take database backups/snapshots before schema changes and before testing full reloads. Test restore procedures, not just backup creation.
6. **Control model spending:** configure provider budgets/quotas; test one source/table/view/month first; use `FRESH_RULES = false` and `FRESH_SQL = false` for ordinary repeat runs unless fresh generation is the explicit objective.
7. **Review AI-generated changes:** inspect dry-run samples, approve risky cleaning rules, and retain SQL validation/reconciliation. Never treat generated SQL or narrative as automatically correct.
8. **SQL safety:** preserve the transformation role boundary (`transform_agent` writes views in `models`; publishing is a separate controlled step). Do not disable guardrails or publish after failed checks. Explain's approved-column/value handling should remain intact.
9. **Monitor and log:** inspect n8n execution history and `ops.agent_logs`; retain run IDs and compare row counts. Avoid logging credentials or sensitive payloads.
10. **Production scheduling:** only enable the nightly transformation trigger after manual tests. It is configured for 02:00 in the n8n runtime timezone. Do not assume a missing orchestrator is present; schedule collection → cleaning → transformation → Explain only after you have built/reviewed a real orchestrator and approval-timeout policy.
11. **Network configuration:** `localhost` is relative to the process/container making the request. For Docker or remote deployments, use the appropriate service hostname and restrict webhook exposure.
12. **Capacity:** plan for raw plus clean and working copies; geolocation is the largest table. Monitor storage and execution memory, and use batches.

## J. Final verification checklist

### Database and services
- [ ] Supabase project created; connection tested with SSL and an appropriate pooler/endpoint.
- [ ] SQL scripts installed in the documented order; no partial role/function/table setup remains.
- [ ] All nine `raw.*` tables and required `ops.*`, `clean.*`, `models.*`, `analytics.*`, and `insights.*` objects exist.
- [ ] `transform_agent` and analytics reader permissions reviewed and least-privilege.
- [ ] Google Drive folder contains only the intended CSV source files.
- [ ] Spreadsheet contains tabs `products` and `category_translation` with values preserved as text.
- [ ] Mock API can return valid pages for payments and reviews.
- [ ] Anthropic and Gemini credentials tested; model IDs and spending limits verified.
- [ ] Metabase connects with a read-only account.

### Workflow import and configuration
- [ ] All nine workflows imported in the order in section E.
- [ ] Every Postgres, Google Drive, Google Sheets, Anthropic, and Gemini node has a credential selected.
- [ ] Collection parent points to the current CSV, Sheet, and API loader workflows.
- [ ] Drive file IDs, spreadsheet ID, mock API URL, and mock API file mappings are configured.
- [ ] Cleaning approval form URL and resume behavior tested.
- [ ] `ONLY`, `FRESH_RULES`, `FRESH_SQL`, `MONTHS`, and `KPIS` controls reviewed.
- [ ] No workflow contains real secrets in Code nodes or plain-text parameters.
- [ ] Production publishing/scheduling is enabled only where deliberately required.

### Pipeline validation
- [ ] Mock API tested independently.
- [ ] Small CSV, Sheet, and API source loads tested independently.
- [ ] Collection full run completes; row counts and contracts/mismatch reports reviewed.
- [ ] Cleaning tested on one table; dry-run results and human approval gate reviewed.
- [ ] All clean tables and quality checks reviewed.
- [ ] Transformation tested on one view and then all views; reconciliation passes.
- [ ] Failed transformation path verified not to publish partial tables.
- [ ] Explain run passes reconciliation and publishes insight rows.
- [ ] Metabase dashboard totals agree with direct SQL; insights and refresh status are populated.
- [ ] Backups, logs, and rollback/restore approach documented.
- [ ] Any deployment-specific unknowns (database role setup, provider model availability, dashboard click behavior) have been confirmed.

## Source references inside the supplied archives

- Collection setup and source details: `collection_workflow/n8n/README.md`, `collection_workflow/docs/collection_sources_guide.md`, `collection_workflow/scripts/raw_tables.sql`, `collection_workflow/n8n/ops_tables.sql`.
- Cleaning and transformation setup/contracts: `Cleaning_Transformation_Package/README.md`, `docs/CLEANING.md`, `docs/TRANSFORMATION.md`, and `sql/01_raw_tables.sql` through `sql/04_transform_tables.sql`.
- Explain setup and dashboard: `explain_phase/n8n/EXPLAIN.md`, `scripts/insights_tables.sql`, `metabase/DASHBOARD.md`, and `metabase/dashboard.env.example`.
