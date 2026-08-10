# Job Hunter - n8n Workflows

Scraping workflows for job vacancy aggregation. Part of the [Job Hunter](https://github.com/mshykhov/job-hunter) system.

## Overview

n8n workflows that periodically scrape job listings from multiple platforms and send normalized data to the Job Hunter API via REST.

### Platforms

| Platform | Method | Market | Status |
|----------|--------|--------|--------|
| [DOU](https://jobs.dou.ua) | RSS feed | Ukraine | Live |
| [Djinni](https://djinni.co) | HTML scraping | Ukraine | Planned |
| [LinkedIn](https://linkedin.com) | via Google Jobs / JSearch | International | Planned |
| [Google Jobs](https://www.google.com/search?q=jobs) | SerpAPI / scraping | International | Planned |
| [Landing.jobs](https://landing.jobs) | REST API (`/api/v1/jobs`) | EU remote | Doc |
| [JustJoinIT](https://justjoin.it) | REST API (`api.justjoin.it/v2`) | EU / B2B | Doc |
| [NoFluffJobs](https://nofluffjobs.com) | Search API (POST) | CEE / B2B | Doc |

## Quick Start

```bash
cp .env.example .env       # fill in values (see below)
docker compose up -d       # starts n8n + PostgreSQL
```

Open [http://localhost:5678](http://localhost:5678) to access the n8n editor.

### Environment Variables

See `.env.example` for all variables. Key ones:

| Variable | Description |
|----------|-------------|
| `DB_POSTGRESDB_PASSWORD` | PostgreSQL password |
| `N8N_ENCRYPTION_KEY` | Encryption key for credentials (generate once: `openssl rand -hex 32`) |
| `TELEGRAM_BOT_TOKEN` | Telegram bot token for scraper logs/alerts |
| `TELEGRAM_CHAT_ID` | Telegram chat ID for notifications |
| `JOB_HUNTER_API_URL` | Job Hunter API URL (default: `http://host.docker.internal:8095`) |

## Workflow Management

Workflows are edited in the n8n UI and version-controlled as normalized JSON exports
(`workflows/*.json`, one slug-named file per workflow).

```bash
# Export workflows from an n8n instance to Git (REST API)
N8N_URL=https://... N8N_KEY=... ./scripts/export.sh

# Deploy workflows from Git to an n8n instance (REST API, drift-guarded)
N8N_URL=https://... N8N_KEY=... TELEGRAM_BOT_TOKEN=... ./scripts/deploy.sh

# Import workflows into a local docker n8n (CLI)
./scripts/import.sh
```

Pushing `workflows/**` to master triggers the deploy via GitHub Actions. The deploy
aborts when the target instance has changes missing from git history (drift-guard) -
resync with `export.sh` + commit, or override with `FORCE=1`.

## Agent Configuration

`.rulesync/` is the canonical source for repository instructions, scoped rules, and
workflow skills. `CLAUDE.md`, `AGENTS.md`, `.claude/`, and `.agents/` contain generated
target projections and must not be edited directly.

```bash
npm ci
npm run rulesync:dry-run
npm run rulesync:generate
npm run rulesync:verify
```

## Architecture

```
Schedule (every 15 min)
  → Fetch (RSS / HTTP scrape)
  → Parse & normalize
  → POST /jobs/ingest → Job Hunter API
```

Each workflow produces a normalized JSON payload:

```json
{
  "title": "Senior Java Developer",
  "company": "Company Name",
  "url": "https://...",
  "description": "Full job description...",
  "source": "DOU",
  "salary": "$4000-6000",
  "location": "Remote",
  "remote": true
}
```
