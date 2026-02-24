# Job Hunter — n8n Workflows

Scraping workflows for job vacancy aggregation. Part of the [Job Hunter](https://github.com/mshykhov/job-hunter) system.

## Overview

n8n workflows that periodically scrape job listings from multiple platforms and send normalized data to the Job Hunter API via REST.

### Supported Platforms

| Platform | Method | Market |
|----------|--------|--------|
| [DOU](https://jobs.dou.ua) | RSS feed | Ukraine |
| [Djinni](https://djinni.co) | HTML scraping | Ukraine |
| [Indeed](https://indeed.com) | RSS feed | International |

## Quick Start

```bash
cp .env.example .env       # fill in values (see below)
docker compose up -d       # starts n8n + PostgreSQL
```

Open [http://localhost:5678](http://localhost:5678) to access the n8n editor.

### Environment Variables

| Variable | Description |
|----------|-------------|
| `DB_POSTGRESDB_PASSWORD` | PostgreSQL password |
| `N8N_ENCRYPTION_KEY` | Encryption key for credentials (generate once: `openssl rand -hex 32`) |

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
Schedule (every 2h)
  → Fetch (RSS / HTTP scrape)
  → Parse & normalize
  → POST /api/jobs/ingest → Job Hunter API
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
