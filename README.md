# job-hunter-n8n

n8n workflows for job vacancy scraping.

## Quick Start

```bash
cp .env.example .env    # fill in values
docker compose up -d    # http://localhost:5678
```

## Workflow Management

```bash
./scripts/export.sh     # n8n → Git
./scripts/import.sh     # Git → n8n
```
