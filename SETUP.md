# Setup guide

How to install the dependencies and run the Olist Data Analytics Pipeline, with n8n either **locally** or in the **cloud**. For what the project is and how the stages fit together, see [README.md](README.md). For the dependency list, see [requirements.txt](requirements.txt).

Contents

1. [What you need](#1-what-you-need)
2. [Get the code](#2-get-the-code)
3. [Set up n8n](#3-set-up-n8n) — [local (Docker)](#3a-local-with-docker-recommended) · [local (npm)](#3b-local-with-npm) · [n8n Cloud](#3c-n8n-cloud) · [self-hosted server](#3d-self-hosted-on-a-cloud-server)
4. [Set up Supabase and the database](#4-set-up-supabase-and-the-database)
5. [Prepare the source data (Google Drive / Sheets)](#5-prepare-the-source-data-google-drive--sheets)
6. [Create n8n credentials](#6-create-n8n-credentials)
7. [Import the workflows](#7-import-the-workflows)
8. [Configure the workflows](#8-configure-the-workflows)
9. [Run and test the pipeline](#9-run-and-test-the-pipeline)
10. [Set up Metabase](#10-set-up-metabase)
11. [Troubleshooting](#11-troubleshooting)
12. [Security notes](#12-security-notes)

---

## 1. What you need

This repo contains n8n workflows (`n8n/*.json`), SQL (`setup/sql/*.sql`) and Metabase config (`setup/metabase/`). There are **no Python or npm packages to install** for the project itself; you install the tools and create the accounts below.

| Need | Used for | Notes |
|---|---|---|
| Git | cloning the repo | |
| n8n | runs the workflows | Minimum version `2.42.7`; local (Docker or npm) or cloud |
| Docker (optional, recommended) | local n8n and Metabase | Docker Desktop, or Docker Engine + Compose plugin |
| Node.js (only for the npm route) | local n8n via npm | use a version supported by your n8n release |
| Supabase project | PostgreSQL 15+ database (minimum version 15) | any PostgreSQL 15 or newer works, but the guides target Supabase |
| Olist dataset | source data | [Kaggle: Brazilian E-Commerce](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce) |
| Google account + Google Cloud project | Drive/Sheets sources | Drive API and Sheets API enabled (needed for self-hosted n8n OAuth) |
| Anthropic API key | Collection workflow (`claude-sonnet-5-5`) | |
| Google Gemini API key | Cleaning, Transformation, Explain (`models/gemini-2.5-flash`) | |
| Metabase | dashboard | started from `setup/metabase/docker-compose.yml` |

Set a spending limit/quota on both LLM accounts before running the full pipeline. Confirm the two model IDs are still available to your accounts; if you change one, change it in every model node that uses it.

## 2. Get the code

```sh
git clone https://github.com/The-Product-Works/DA_web.git
cd DA_web
```

Layout: `n8n/` workflows · `setup/sql/` database scripts · `setup/metabase/` dashboard · `setup/docs/` per-stage guides.

## 3. Set up n8n

Pick **one** of 3a–3d. Whichever you choose, you will end up with an n8n editor URL you can open in a browser, then continue at [section 4](#4-set-up-supabase-and-the-database).

### 3a. Local with Docker (recommended)

```sh
docker volume create n8n_data
docker run -it --rm --name n8n \
  -p 5678:5678 \
  -e GENERIC_TIMEZONE="Europe/Berlin" \
  -e TZ="Europe/Berlin" \
  -v n8n_data:/home/node/.n8n \
  docker.n8n.io/n8nio/n8n
```

Open <http://localhost:5678> and create the owner account. Set the timezone to yours; the nightly Transformation schedule (`0 2 * * *`) uses it.

- The named volume `n8n_data` keeps your workflows, credentials and encryption key. Without it, everything is lost when the container stops.
- `2.42.7` is the minimum supported version. The image above pulls the latest release, which satisfies this. If you pin a tag, use `2.42.7` or newer.
- To run in the background, replace `-it --rm` with `-d --restart unless-stopped`.
- Windows PowerShell: put the command on one line, or use a backtick instead of `\` for line continuation.

### 3b. Local with npm

```sh
node --version          # check against the requirements of your n8n release
npm install -g n8n      # version 2.42.7 or newer
n8n start
```

Open <http://localhost:5678>. Data is stored in `~/.n8n`; back it up, including the encryption key in `~/.n8n/config`.

### 3c. n8n Cloud

1. Sign up at <https://n8n.io> and start a workspace. You get a URL like `https://<your-workspace>.app.n8n.cloud`.
2. Nothing else to install. Google OAuth credentials use n8n's built-in sign-in flow, so you do **not** need your own Google Cloud OAuth client (section 6).
3. Check your plan's limits on active workflows and executions. Loading ~1M geolocation rows is the heaviest step.
4. n8n Cloud must reach Supabase over the internet. Supabase allows this by default; if you restrict network access, allow n8n Cloud's IPs.

### 3d. Self-hosted on a cloud server

For a VPS (or any host with Docker) where you want n8n reachable on a domain with HTTPS. Webhooks, the cleaning approval form and Google OAuth all need the **public** URL, so these variables matter.

`docker-compose.yml` (put it in a directory on the server, not in this repo):

```yaml
services:
  n8n:
    image: docker.n8n.io/n8nio/n8n
    restart: unless-stopped
    ports:
      - "127.0.0.1:5678:5678"      # expose publicly only through a reverse proxy
    environment:
      - N8N_HOST=n8n.example.com
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://n8n.example.com/
      - GENERIC_TIMEZONE=Europe/Berlin
      - TZ=Europe/Berlin
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
    volumes:
      - n8n_data:/home/node/.n8n
volumes:
  n8n_data:
```

1. Create a `.env` file beside it with `N8N_ENCRYPTION_KEY=<long random string>` (for example `openssl rand -hex 32`). Keep it private and **back it up**: without it, saved credentials cannot be decrypted after a restore.
2. Point a DNS record at the server and put a reverse proxy with TLS in front (Caddy, nginx, Traefik) forwarding to `127.0.0.1:5678`, with WebSocket support.
3. `docker compose up -d`, then open `https://n8n.example.com` and create the owner account.
4. Restrict who can reach the editor and the cleaning approval form (firewall, VPN, or proxy auth).

Because n8n runs on a server, the default `MOCK_API_URL` (`http://localhost:5678/webhook/olist-mock-api`) still works: the mock API is a workflow on the same n8n and `localhost` resolves to that n8n process or container. If you ever call a service on another container or host, use its service name or address instead.

## 4. Set up Supabase and the database

1. Create a Supabase project and save the database password.
2. Check you have storage for the data (geolocation alone is about 1,002,183 rows, and the pipeline keeps raw, working, clean and analytics copies).
3. In the Supabase **SQL Editor**, run these files **in this order**, one at a time:

   | # | File | Creates |
   |---|---|---|
   | 1 | `setup/sql/cleaning_01_raw_tables.sql` | `raw` schema, nine landing tables (all text columns) |
   | 2 | `setup/sql/cleaning_02_ops_tables.sql` | `ops.agent_logs`, `ops.data_contracts` |
   | 3 | `setup/sql/cleaning_03_clean_tables.sql` | `clean` typed tables, `cleaning` helpers, rule/approval/quarantine tables |
   | 4 | `setup/sql/cleaning_04_transform_tables.sql` | `models`, `analytics`, `transform` schemas, roles `transform_agent` and `analytics_reader`, publish functions |
   | 5 | `setup/sql/insights_tables.sql` | `insights` schema, KPI config, insight tables |

   Do **not** run `collection_raw_tables.sql` or `collection_ops_tables.sql`. They are earlier, overlapping versions of 1 and 2 (the `cleaning_` versions add the `profile` column the cleaning stage needs).
4. Read `cleaning_04_transform_tables.sql` before running it: it creates roles and grants. If Supabase rejects a role statement, have an admin adapt it to the least-privilege equivalent. Do not give the AI or dashboard login owner/superuser rights.
5. Check the install:

   ```sql
   select table_schema, table_name
   from information_schema.tables
   where table_schema in ('raw','ops','clean','analytics','insights')
   order by 1, 2;
   ```

   Expected schemas: `raw`, `ops`, `cleaning`, `clean`, `models`, `transform`, `analytics`, `insights`.
6. Get connection details from the Supabase **Connect** dialog. Use the **Session pooler** (direct connections may need IPv6). You need host, port, database (`postgres`), user (the pooler user includes the project ref) and password. SSL must be on.

## 5. Prepare the source data (Google Drive / Sheets)

No dataset is included in this repo. The workflows read from Google Drive, Google Sheets and a mock API, not from a local folder. Supply the Olist data yourself.

**Dataset:** [Olist Brazilian E-Commerce on Kaggle](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce) (public, about 100,000 real orders; a free Kaggle account is needed to download). The pipeline is designed for a deliberately messy copy of this data (mixed date formats, decimal commas, blank rows, repeated headers), which is what the cleaning stage is meant to handle. The original Kaggle files work for a first run but will show fewer cleaning issues.

**Drive folder for CSVs.** Create a folder and upload `orders.csv`, `order_items.csv`, `customers.csv`, `sellers.csv`, `geolocation.csv`. Keep them as plain files (do not convert to Sheets). Note each file ID from its URL. **Never upload `answer_key.csv`.**

**Spreadsheet.** Create one spreadsheet with tabs named exactly `products` and `category_translation`. Import without converting text to numbers/dates (keep leading-zero ZIP prefixes and decimal commas as text). Note the spreadsheet ID from the URL (not the tab name).

**Mock API files.** Upload `payments.json` and `reviews.json` to a Drive folder and note both file IDs. The `Mock API` workflow serves them as paginated JSON.

Details on column contracts and counts: [setup/docs/collection_sources_guide.md](setup/docs/collection_sources_guide.md).

## 6. Create n8n credentials

In n8n: **Credentials → Create credential**. The workflow exports contain no credentials, so you create them and then select them on the nodes after import.

| Credential | Fields | Used by |
|---|---|---|
| **Postgres** (name it `Supabase`) | Supabase session-pooler host, port, database, user, password, SSL on | every Postgres node, all workflows |
| **Google Drive OAuth2** | see below | `Collection · Load CSV from Drive`, `Mock API` |
| **Google Sheets OAuth2** | see below | `Collection · Load Sheet tab` |
| **Anthropic** | API key | `Collection · Main` (`Contract model`, `Mismatch model`) |
| **Google Gemini (PaLM) API** | API key | `Cleaning · Main`, `Transformation · Main`, `Explain · Main` (including repair models) |

**Google OAuth, n8n Cloud:** choose "Sign in with Google" in the credential dialog and approve access.

**Google OAuth, local or self-hosted n8n:**

1. In Google Cloud Console, create or select a project and enable the **Google Drive API** and **Google Sheets API**.
2. Configure the OAuth consent screen. While the app is in testing mode, add your Google account as a test user.
3. Create an OAuth client ID (type "Web application"). Copy the **OAuth Redirect URL** shown in the n8n credential dialog into the client's authorized redirect URIs. Locally it looks like `http://localhost:5678/rest/oauth2-credential/callback`; on a server it uses your public domain.
4. Paste the client ID and secret into n8n and click **Sign in with Google**.

Keep the Postgres credential's role scoped to what the workflows need. Use a separate read-only login for Metabase (section 10).

## 7. Import the workflows

For each file: **Workflows → ⋯ → Import from File**, then save. Import in this order (child workflows before the parent that calls them):

| # | File (`n8n/`) | Workflow |
|---|---|---|
| 1 | `mock_api.json` | Mock API · Olist payments & reviews |
| 2 | `collect_load_csv.json` | Collection · Load CSV from Drive |
| 3 | `collect_load_sheet.json` | Collection · Load Sheet tab |
| 4 | `collect_load_api.json` | Collection · Load API source |
| 5 | `collection_main.json` | Collection · Main |
| 6 | `1_cleaning_approval.json` | Cleaning · Approve rules |
| 7 | `2_cleaning_main.json` | Cleaning · Main |
| 8 | `3_transformation_main.json` | Transformation · Main |
| 9 | `explain_main.json` | Explain · Main |

No orchestrator workflow is included; you run the stages one after another.

## 8. Configure the workflows

1. **Credentials.** Open every workflow and select the credential on each node that needs one (table in section 6). Missing credentials are the most common import problem.
2. **Mock API.** In `Mock API`, open the `Pick file` Code node and set the Drive file IDs for `payments` and `reviews`. Then **publish** the workflow so the production webhook (`/webhook/olist-mock-api`) is live.
3. **Collection · Main → `Sources` Code node.** Replace every `PASTE_ID` in `DRIVE_FILE_IDS` (orders, order_items, customers, sellers, geolocation), set `SPREADSHEET_ID`, and check `MOCK_API_URL`:
   - local n8n: `http://localhost:5678/webhook/olist-mock-api` (the default) works.
   - n8n Cloud or a server with a domain: `https://<your-n8n-host>/webhook/olist-mock-api`.
   - Use the production `/webhook/` URL, not `/webhook-test/`.
4. **Sub-workflow links.** In `Collection · Main`, open each of the three Execute Workflow nodes and re-select the matching child workflow from the list (IDs change on import). Keep "wait for completion" on.
5. **Cleaning · Main → `Tables` Code node.** Check `ONLY`, `FRESH_RULES` (leave `false`) and `APPROVAL_FORM_URL`. Set the form URL to the production URL of the `Cleaning · Approve rules` form on **your** n8n (local: `http://localhost:5678/form/...`; cloud: your public host).
6. **Transformation · Main.** `ONLY` and `FRESH_SQL` (leave `false`). Leave the 02:00 Schedule Trigger inactive until the manual tests pass.
7. **Explain · Main → `Settings`.** `MONTHS` and `KPIS`. Make sure `insights.kpi_config` has at least one enabled KPI.

## 9. Run and test the pipeline

Use a development database first. Loaders **truncate** each raw table before reloading it.

1. **Mock API:** open the production URL with `?source=payments&page=1`; expect JSON with `page`, `total_pages` and `data`.
2. **Collection:** in `Sources`, set `ONLY` to one small source (for example `['sellers']`), run `Collection · Main`, and check `raw.sellers_csv` and `ops.agent_logs`. Repeat for one Sheets source and one API source, then clear `ONLY` to load all nine. Defaults: batch size 2,000; geolocation 5,000.
3. **Cleaning:** set `ONLY` to `['sellers']` and run `Cleaning · Main`. If rules need approval, open the `Cleaning · Approve rules` form, decide, and submit; the run resumes. Undecided rules expire after 2 hours. Then run all tables (geolocation is slowest).
4. **Transformation:** set `ONLY` to `['kpi_summary']`, run, check `ops.transform_models` and `analytics.*`, then run all views.
5. **Explain:** run with a single month first (for example `['2018-03']`), then check `analytics.insight_summary`, `analytics.insight_causes`, `analytics.insight_recommendations`.
6. **Compare** a few `analytics.*` totals against direct SQL.

The Explain and dashboard docs state that real Gemini output and some Metabase click-throughs were not validated by the authors, so treat your first run as an integration test.

Stage details: [CLEANING](setup/docs/CLEANING.md) · [TRANSFORMATION](setup/docs/TRANSFORMATION.md) · [EXPLAIN](setup/docs/EXPLAIN.md).

## 10. Set up Metabase

Full steps are in [setup/metabase/README.md](setup/metabase/README.md). In short:

```sh
cd setup/metabase
docker compose up -d       # http://localhost:3000, create the admin account on first visit
```

Then create a read-only database login (based on the `analytics_reader` role created by `cleaning_04_transform_tables.sql`) and add Supabase as a PostgreSQL database in Metabase using the session pooler. Through the pooler the username must be `<role>.<project-ref>`. Build the dashboard from [setup/metabase/DASHBOARD.md](setup/metabase/DASHBOARD.md). `dashboard.env.example` refers to a `build_metabase_dashboard.py` script that is not in this repo, so the dashboard is built manually. The Compose file uses `metabase/metabase:latest`; pin a version tag for anything beyond a demo.

## 11. Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| Nodes show "credentials not set" after import | Exports carry no credentials. Select the credential on each node. |
| Postgres timeout / refused | Use the **session pooler** details from Supabase's Connect dialog, SSL on; check the n8n host can reach Supabase. |
| "Tenant or user not found" | Pooler username needs the project ref suffix (`user.<project-ref>`). |
| "relation does not exist" | SQL run out of order, or `collection_*` scripts mixed with `cleaning_*`. Reinstall in the section 4 order. |
| "permission denied" for a schema | Roles/grants from `cleaning_04_transform_tables.sql` missing; ask an admin to apply them. Do not grant superuser. |
| "Workflow does not exist" in Execute Workflow | Re-select the child workflow in each of the three nodes. |
| Loader workflow fails when run alone | It expects input from `Collection · Main`; run the parent with `ONLY`. |
| API loader returns nothing | Mock API not **published**, wrong or `/webhook-test/` URL, or response missing `page`/`total_pages`/`data`. |
| Google Drive/Sheets errors | Wrong file or spreadsheet ID, file not accessible to the connected account, API not enabled, or OAuth redirect URI mismatch. |
| Google OAuth "redirect_uri_mismatch" | The redirect URL in Google Cloud must match the one n8n shows, including `https` and your domain. |
| LLM auth / model error | Invalid key, quota or billing, or the model ID is unavailable to your account. |
| Approval form never resumes | `APPROVAL_FORM_URL` wrong for your n8n host, or the 2-hour wait expired. |
| Saved credentials stop working after a restore | The `N8N_ENCRYPTION_KEY` / `~/.n8n/config` key changed. Restore the original key. |
| Empty Metabase dashboard | Pipeline stages not run, read-only role lacks grants, or the Metabase schema is not synced. Explain cards stay empty until Explain has run. |
| Dashboard looks stale | Metabase caching. Refresh the dashboard. |

## 12. Security notes

- Never commit passwords, API keys, OAuth secrets or `.env` files. Keep them in n8n credentials or a secret manager.
- Use separate database logins for n8n (write) and Metabase (read-only).
- Do not give the AI-driven roles owner/superuser rights; keep the `transform_agent` boundary and the validation steps intact.
- Test on a development database and back up before full reloads.
- On a server, protect the n8n editor and webhooks behind HTTPS and access controls.
- Keep the `FRESH_RULES` and `FRESH_SQL` flags `false` for routine runs to avoid repeated model spending.
