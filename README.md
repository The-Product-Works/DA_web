<div align="center">

<img src="assets/logo.jpg" alt="Iburgeon: Build · Scale · Beyond" width="420">

# Olist Data Analytics Pipeline

**From raw e-commerce data to AI-explained KPIs, on n8n, Supabase and Metabase.**

![n8n](https://img.shields.io/badge/n8n-%E2%89%A5%202.42.7-EA4B71?logo=n8n&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-%E2%89%A5%2015-4169E1?logo=postgresql&logoColor=white)
![Supabase](https://img.shields.io/badge/Supabase-database-3ECF8E?logo=supabase&logoColor=white)
![Metabase](https://img.shields.io/badge/Metabase-dashboard-509EE3?logo=metabase&logoColor=white)
![Anthropic](https://img.shields.io/badge/Anthropic-Claude-191919?logo=anthropic&logoColor=white)
![Gemini](https://img.shields.io/badge/Google-Gemini-8E75B2?logo=googlegemini&logoColor=white)

[Quick start](#-quick-start) · [How it works](#-how-it-works) · [Setup guide](SETUP.md) · [Requirements](requirements.txt) · [Docs](#-documentation)

</div>

---

## Overview

An n8n-based pipeline that loads the Olist e-commerce dataset from Google Drive, Google Sheets and a paginated API into Supabase (PostgreSQL). It cleans the data with AI-proposed, human-approved rules, builds validated analytics tables, generates KPI explanations, and shows the results in Metabase.

| | |
|---|---|
| **Dataset** | [Olist Brazilian E-Commerce on Kaggle](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce), about 100,000 real orders |
| **Collect** | Nine sources land untouched in `raw.*` with AI-suggested data contracts |
| **Clean** | AI proposes rules, a person approves the risky ones, typed `clean.*` tables result |
| **Transform** | AI-written SQL is validated under a restricted role, then published to `analytics.*` |
| **Explain** | KPI movements are explained from aggregated data and reconciled before publishing |
| **Visualize** | Metabase dashboards read the published tables |

## 🚀 Quick start

```sh
git clone https://github.com/The-Product-Works/DA_web.git
cd DA_web
```

1. Check the tools and accounts you need in [`requirements.txt`](requirements.txt). There are no Python or npm packages to install for the project itself.
2. Follow **[SETUP.md](SETUP.md)** end to end. It covers:
   - running n8n **locally** (Docker or npm), on **n8n Cloud**, or **self-hosted on a server**
   - Supabase and the SQL scripts, in order
   - Google Drive/Sheets, Anthropic and Gemini credentials
   - importing and configuring the nine workflows
   - running and testing each stage, setting up Metabase, and troubleshooting

## 🧭 How it works

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
| **Collection** | `mock_api`, `collect_load_csv`, `collect_load_sheet`, `collect_load_api`, `collection_main` | `raw.*`, data contracts, mismatch report | Anthropic `claude-sonnet-5-5` |
| **Cleaning** | `1_cleaning_approval`, `2_cleaning_main` | typed `clean.*`, rules, quarantine | Gemini `models/gemini-2.5-flash` |
| **Transformation** | `3_transformation_main` | validated `models.*` views, published `analytics.*` | Gemini `models/gemini-2.5-flash` |
| **Explain** | `explain_main` | `analytics.insight_*` | Gemini `models/gemini-2.5-flash` |
| **Dashboard** | Metabase (`setup/metabase/`) | KPI tiles, trends, insights | none |

### Design principles

- **Raw stays raw.** Source data is kept as received (all text); cleaning is a separate stage.
- **Humans approve risk.** Risky cleaning rules wait for a decision in an n8n form.
- **Guarded AI.** Generated SQL runs under a restricted role, is validated, and is published only after every check passes.
- **Minimal exposure.** Only aggregated data is sent to the model in the Explain stage.
- **Cheap reruns.** Saved rules and SQL are reused, so repeat runs skip the models unless you set `FRESH_RULES` or `FRESH_SQL`.

## 🗂 Repository layout

```text
.
├── n8n/                 n8n workflow exports (import into n8n)
├── setup/
│   ├── sql/             database scripts (run in the order given in SETUP.md)
│   ├── metabase/        docker-compose, dashboard guide, env example
│   └── docs/            per-stage guides
├── assets/              images used in this README
├── SETUP.md             installation and setup guide (local and cloud)
└── requirements.txt     dependency manifest (nothing to pip install)
```

## 📚 Documentation

| Guide | Contents |
|---|---|
| [SETUP.md](SETUP.md) | Full installation and configuration, local and cloud |
| [Collection sources](setup/docs/collection_sources_guide.md) | Source files and column contracts |
| [Cleaning](setup/docs/CLEANING.md) | Profiling, rules, approval, clean tables |
| [Transformation](setup/docs/TRANSFORMATION.md) | Business definitions, SQL validation, publishing |
| [Explain](setup/docs/EXPLAIN.md) | KPI config, reconciliation, insights |
| [Metabase](setup/metabase/README.md) · [Dashboard](setup/metabase/DASHBOARD.md) | Dashboard setup |

## ⚠️ Limitations

- No dataset is bundled. Download the [Olist Brazilian E-Commerce dataset from Kaggle](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce) and provide the files through Google Drive and Sheets (see [SETUP.md](SETUP.md#5-prepare-the-source-data-google-drive--sheets)). The pipeline is built to handle a deliberately messy copy of this data, so the original files may need to be modified for the full cleaning demo.
- No orchestrator workflow is included. Run the stages in order: Collection → Cleaning → Transformation → Explain.
- The Metabase dashboard builder script mentioned in `dashboard.env.example` is not in the repo; build the dashboard manually.
- Explain output from real Gemini runs and some Metabase click-throughs have not been validated by the authors.
