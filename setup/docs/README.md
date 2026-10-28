# Cleaning + Transformation: setup and run order

This guide covers the two cleaning and transformation stages:

- **Cleaning:** `raw.*` → `clean.*`. A Gemini agent proposes rules, and a person approves the risky ones in an n8n Form.
- **Transformation:** `clean.*` → `analytics.*`. A Gemini agent writes SQL, each view is checked against a reference query, and the tables are published all at once.

Follow the steps **in order**. Each step needs the one before it. For the whole pipeline (collection and Explain too, local or cloud n8n), see [SETUP.md](../../SETUP.md).

---

## Where things are

```
setup/sql/
  cleaning_01_raw_tables.sql        raw landing tables (9 tables, all text)
  cleaning_02_ops_tables.sql        ops.agent_logs, ops.data_contracts
  cleaning_03_clean_tables.sql      clean.* tables, cleaning helper functions, rule/approval/quarantine tables
  cleaning_04_transform_tables.sql  models/analytics/transform schemas, roles, validate + publish functions
n8n/
  1_cleaning_approval.json          "Cleaning · Approve rules"   (n8n Form for the approver)
  2_cleaning_main.json              "Cleaning · Main"
  3_transformation_main.json        "Transformation · Main"
setup/docs/
  CLEANING.md                       full explanation of the cleaning workflow
  TRANSFORMATION.md                 full explanation of the transformation workflow
```

Other guides may refer to these SQL files by shorter names: `raw_tables.sql` is `cleaning_01_raw_tables.sql`, `ops_tables.sql` is `cleaning_02`, `clean_tables.sql` is `cleaning_03`, and `transform_tables.sql` is `cleaning_04`.

---

## Before you start

You need:

1. **A Supabase project** (any Postgres 15+ works too).
2. **n8n** running locally at `http://localhost:5678`. The approval form link and the resume call assume this address.
3. **A Gemini API key** from https://aistudio.google.com/apikey.
4. **Data in the `raw.*` tables.** The cleaning stage reads `raw.*`, which the **collection stage** fills. If collection has already run against this database, you're set. If not, run the collection workflows first, or load the messy dataset into the `raw.*` tables some other way. Cleaning has nothing to clean without this data.

---

## Step 1: Create the database objects (Supabase SQL editor)

Run each file once, **in this order**. Each one is safe to run again.

| # | File | Creates |
|---|---|---|
| 1 | `setup/sql/cleaning_01_raw_tables.sql` | `raw` schema + 9 raw tables (skip if collection already created them) |
| 2 | `setup/sql/cleaning_02_ops_tables.sql` | `ops.agent_logs`, `ops.data_contracts` |
| 3 | `setup/sql/cleaning_03_clean_tables.sql` | `clean.*` tables, `cleaning.*` helper functions, `ops.cleaning_rules`, `ops.cleaning_approvals`, `ops.quarantine` |
| 4 | `setup/sql/cleaning_04_transform_tables.sql` | `models`, `analytics` and `transform` schemas; roles `transform_agent` and `analytics_reader`; `transform.validate_view()`, `transform.publish()`; `analytics.refresh_status`; `ops.transform_models` |

---

## Step 2: Create the two n8n credentials

**Postgres credential, named `Supabase`.** In Supabase, click **Connect** and choose **Session pooler**. Don't use the direct connection, because it needs IPv6.

| Field | Value |
|---|---|
| Host | `aws-0-<region>.pooler.supabase.com` |
| Database | `postgres` |
| User | `postgres.<project-ref>` |
| Password | your database password |
| Port | `5432` |
| SSL | `Require` (turn on *Ignore SSL Issues* if n8n reports a certificate error) |

**Gemini credential, named `Gemini`.** Create a *Google Gemini(PaLM) Api* credential and paste your key. The agents use `models/gemini-2.5-flash` at temperature 0.

---

## Step 3: Import the workflows (in this order)

These three come after the collection workflows. The full nine-workflow order is in [SETUP.md](../../SETUP.md#7-import-the-workflows).

In n8n, go to **Overview → Create → Import from file**, or use the CLI with n8n stopped: `n8n import:workflow --input=<file>`.

1. `n8n/1_cleaning_approval.json`
2. `n8n/2_cleaning_main.json`
3. `n8n/3_transformation_main.json`

Then open each workflow and pick the credential on every node with a red warning triangle:

| Workflow | Nodes that need `Supabase` | Nodes that need `Gemini` |
|---|---|---|
| Cleaning · Approve rules | Get pending rules, Save decisions, Log approval | – |
| Cleaning · Main | Get stored rules, Build working copy, Profile columns, Profile table, Get contract, Dry run rules, Save rules, Log proposal, Log reuse, Count pending rules, Save approval request, Log waiting, Expire undecided rules, Get rules to apply, Run cleaning SQL, Log cleaning, Check clean tables, Log run | Cleaning model |
| Transformation · Main | Get stored SQL, Get schema, Create and validate view, Save attempt, Create and validate again, Save retry, Log failure, Publish tables, Run summary, Log run | Transformation model, Repair model |

**Save** each workflow after assigning its credentials.

**Publish `Cleaning · Approve rules`** using the **Publish** button at the top right. Its form only responds at the production URL when the workflow is published.

---

## Step 4: Run cleaning

1. Open **Cleaning · Main**.
2. *(Recommended for a first test)* In the `Tables` node, set `ONLY = ['sellers']` to clean only one small table.
3. Click **Execute workflow**.
4. If the agent proposes risky rules, the run **pauses** at *Wait for approval*.
   - Open **http://localhost:5678/form/olist-cleaning-approval**. The link is also in the `Log waiting` row of `ops.agent_logs`.
   - Enter your name, choose **Approve** or **Reject** for each rule, and submit.
   - The paused run continues by itself. If nobody answers within **2 hours**, undecided rules are treated as rejected.
5. Once the test works, set `ONLY = []` and run again to clean all nine tables.

Check the result:

```sql
select action, source, status, rows_read, rows_written, reason
from ops.agent_logs where agent = 'cleaning' order by logged_at desc limit 40;

select source, rule_order, rule_type, column_name, risk, status, rows_affected, decided_by
from ops.cleaning_rules order by source, rule_order;
```

Note: a **rejected** rule turns the values it would have fixed into null. For example, rejecting `parse_date` on `order_purchase_timestamp` leaves about 14,000 purchase dates empty. This is intended.

---

## Step 5: Run transformation

Only start this after cleaning has finished for **all** tables.

1. Open **Transformation · Main**.
2. *(Optional test)* In the `Questions` node, set `ONLY = ['kpi_summary']`.
3. Click **Execute workflow**.
4. For each question, the agent writes SQL and the workflow creates a view and checks it. If a check fails, the repair agent gets one more try. If it fails again, the run stops and **nothing is published**. The dashboard then keeps the previous good data.
5. If every view passes, all `analytics.*` tables are published in one transaction.

Check the result:

```sql
select * from analytics.refresh_status order by table_name;

select view_name, attempt, origin, status, error
from ops.transform_models order by created_at desc;
```

Output tables: `analytics.kpi_summary`, `monthly_revenue`, `revenue_by_state`, `top_categories`, `orders_wide`, `order_items_wide`.

---

## Step 6 (optional): Read-only login for Metabase or another BI tool

```sql
create role metabase_reader login password '<choose one>' in role analytics_reader;
```

Connect with the user `metabase_reader.<project-ref>` through the Session pooler. This login can read only `analytics.*` and `ops.agent_logs`.

---

## Re-runs and scheduling

- **Re-runs are cheap.** Saved cleaning rules and saved transformation SQL are reused, so there's no AI call and no approval form. To get fresh proposals, set `FRESH_RULES = true` (in `Tables`) or `FRESH_SQL = true` (in `Questions`).
- **Nightly run:** in Transformation · Main, enable the `Every night` trigger (02:00, off by default) and publish the workflow.

For more detail, see [CLEANING.md](CLEANING.md) and [TRANSFORMATION.md](TRANSFORMATION.md).
