# Olist Data Analytics Pipeline

An n8n-based data pipeline that loads the Olist e-commerce dataset from Google Drive, Google Sheets and a paginated API into Supabase (PostgreSQL), cleans it with AI-proposed and human-approved rules, builds validated analytics tables, generates KPI explanations, and shows the results in Metabase.

## Quick start

1. Clone the repo and install the tools you need (n8n, Docker, accounts): see [requirements.txt](requirements.txt).
2. Follow **[SETUP.md](SETUP.md)** end to end. It covers:
   - running n8n **locally** (Docker or npm), on **n8n Cloud**, or **self-hosted on a server**
   - Supabase and the SQL scripts, in order
   - Google Drive/Sheets, Anthropic and Gemini credentials
   - importing and configuring the nine workflows
   - running and testing each stage, setting up Metabase, and troubleshooting

```sh
git clone https://github.com/The-Product-Works/DA_web.git
cd DA_web
```

There are no Python or npm packages to install for the project itself. `requirements.txt` lists the external software and services.

## How it works

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
```

| Stage | Workflows (`n8n/`) | Output | LLM |
|---|---|---|---|
| Collection | `mock_api`, `collect_load_csv`, `collect_load_sheet`, `collect_load_api`, `collection_main` | `raw.*`, data contracts, mismatch report | Anthropic `claude-sonnet-5-5` |
| Cleaning | `1_cleaning_approval`, `2_cleaning_main` | typed `clean.*`, rules, quarantine | Gemini `models/gemini-2.5-flash` |
| Transformation | `3_transformation_main` | validated `models.*` views, published `analytics.*` | Gemini `models/gemini-2.5-flash` |
| Explain | `explain_main` | `analytics.insight_*` | Gemini `models/gemini-2.5-flash` |
| Dashboard | (Metabase, `setup/metabase/`) | KPI tiles, trends, insights | none |

Key design points:

- Raw data is kept as received (all text). Cleaning happens in a separate stage.
- Risky cleaning rules wait for a human decision in an n8n form.
- AI-generated SQL runs under a restricted role, is validated, and is published only after every check passes.
- Only aggregated data is sent to the model in the Explain stage.
- Saved rules and SQL are reused, so repeat runs do not call the models again unless you set `FRESH_RULES` or `FRESH_SQL`.

## Repository layout

```text
n8n/                  n8n workflow exports (import into n8n)
setup/sql/            database scripts (run in the order given in SETUP.md)
setup/metabase/       Metabase docker-compose, dashboard guide, env example
setup/docs/           per-stage guides: collection, cleaning, transformation, explain, dashboard
SETUP.md              installation and setup guide (local and cloud)
requirements.txt      dependency manifest (software and services; nothing to pip install)
```

## Documentation

- [SETUP.md](SETUP.md): full installation and configuration
- [setup/docs/collection_sources_guide.md](setup/docs/collection_sources_guide.md): source files and column contracts
- [setup/docs/CLEANING.md](setup/docs/CLEANING.md), [TRANSFORMATION.md](setup/docs/TRANSFORMATION.md), [EXPLAIN.md](setup/docs/EXPLAIN.md): stage details
- [setup/metabase/README.md](setup/metabase/README.md), [DASHBOARD.md](setup/metabase/DASHBOARD.md): dashboard setup

## Limitations

- No dataset is bundled; you provide the Olist files through Google Drive and Sheets.
- No orchestrator workflow is included. Run the stages in order: Collection → Cleaning → Transformation → Explain.
- The Metabase dashboard builder script mentioned in `dashboard.env.example` is not in the repo; build the dashboard manually.
- Explain output from real Gemini runs and some Metabase click-throughs have not been validated by the authors.
