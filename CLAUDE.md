# job-hunter-n8n

**TL;DR:** n8n scraping workflows for [Job Hunter](https://github.com/mshykhov/job-hunter). Collects vacancies from job platforms (DOU, Djinni, LinkedIn, ...) and sends them to the API via REST.

> **Stack**: n8n 2.10 (Community), PostgreSQL 16, Docker Compose

## Portfolio Project

**Public repository.** Everything must be clean and professional:
- **English only** - README, commits, CLAUDE.md
- **Conventional commits**, no test/temporary workflows in master
- **No AI mentions** in commits, no Co-Authored-By or any trailer referencing Claude/AI

## AI Guidelines

### Principles
- **Workflows are config, not code** - edit via n8n UI or MCP (the `n8n` MCP server also reads executions and node docs), never hand-edit workflow JSON in `workflows/`
- **No secrets in code** - API keys, tokens via .env (gitignored)
- **N8N_ENCRYPTION_KEY** - one key across all environments, otherwise credentials can't be decrypted
- **Environment variables** for all external config (Telegram, API keys) - no manual credential setup in n8n UI

### Workflow Development Process
**IMPORTANT: Doc first, then build.**
1. **Design** - create/update doc in `docs/workflows/{name}.md` with flow diagram, node config, parsed fields, edge cases, and observability
2. **Build** - construct workflow in n8n UI (or via MCP) following the doc
3. **Test** - run each node step by step, verify output matches doc
4. **Sync** - `scripts/export.sh`, then commit

### Sync & Deploy
The n8n instance is where workflows are edited; git is where they are versioned:
- **Export**: `N8N_URL=... N8N_KEY=... scripts/export.sh` - writes normalized, slug-named JSON to `workflows/` (`normalize.jq` strips runtime noise). Run after every UI/MCP edit, then commit
- **Deploy**: push to `workflows/**` on master → GitHub Actions runs `scripts/deploy.sh` (REST PUT/POST matched by workflow name, sub-workflow/credential IDs remapped)
- **Drift-guard**: deploy aborts if prod state is not reproducible from the git history of a workflow file (someone edited prod without exporting). Resync with export.sh + commit, or `FORCE=1` to overwrite
- **Active state** is per-environment, never synced from git

### Structure
```
job-hunter-n8n/
├── docker-compose.yml      # n8n + PostgreSQL (local dev)
├── .env                    # Secrets (gitignored)
├── docs/
│   └── workflows/          # Workflow design docs (source of truth)
├── scripts/
│   ├── export.sh           # Export workflows from an n8n instance (REST) to workflows/
│   ├── deploy.sh           # Deploy workflows/ to an n8n instance (REST, drift-guarded)
│   ├── normalize.jq        # Shared canonical workflow representation
│   └── import.sh           # Import workflows into local docker n8n (CLI)
├── workflows/              # Workflow JSON exports (version-controlled, slug-named)
├── CLAUDE.md
└── README.md
```

### Workflow Conventions
- One platform = one scraper workflow (folder: Scrapers, tags: `scraper` + platform), Schedule Trigger every 15 minutes
- Shared sub-workflows for reusable operations (folder: Shared, tag: `shared`); all receive a `source` parameter identifying the caller (e.g., `"dou"`)
- Sub-workflows handle their own error logging (Format Error → Telegram Notify → Throw); a scraper only logs its own direct HTTP errors
- Shared contracts: **Get Criteria** `{source}`, **Send Jobs** `{body, count, source}` (has-jobs check + POST + logging), **Telegram Notify** `{level, message, source}`, **Get Proxies**, **Check URLs** `{urls, source}` - full I/O details in `docs/workflows/`

### Job Hunter API
- **API Spec (local):** http://localhost:8095/api-docs - check endpoints, schemas, enums (e.g., `source` values)

### Deployment
- Local: `docker compose up -d`
- Production: Helm chart in smhomelab/deploy, ArgoCD
- Credentials are re-created manually on each instance
