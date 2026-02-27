# Job Hunter — n8n Workflows

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

Workflows are edited in the n8n UI and version-controlled as JSON exports.

```bash
# Export workflows from n8n to Git
./scripts/export.sh

# Import workflows from Git into n8n
./scripts/import.sh
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
