# job-hunter-n8n

**TL;DR:** n8n scraping workflows for [Job Hunter](https://github.com/mshykhov/job-hunter). Collects vacancies from job platforms (DOU, Djinni, LinkedIn, Google Jobs) and sends them to the API via REST.

> **Stack**: n8n 2.10 (Community), PostgreSQL 16, Docker Compose

---

## Portfolio Project

**Public repository.** Everything must be clean and professional.

### Standards
- **English only** — README, commits, CLAUDE.md
- **Meaningful commits** — conventional commits
- **No junk** — no test/temporary workflows in master
- **No AI mentions** in commits

---

## AI Guidelines

### Principles
- **Workflows are config, not code.** Edit in n8n UI, sync via Source Control
- **Never edit workflow JSON manually** — only via n8n UI or MCP
- **No secrets in code** — API keys, tokens via .env (gitignored)
- **N8N_ENCRYPTION_KEY** — one key across all environments. Without it, credentials can't be decrypted
- **Environment variables** for all external config (Telegram, API keys) — no manual credential setup in n8n UI

### Workflow Development Process
**IMPORTANT: Doc first, then build.**
1. **Design** — create/update doc in `docs/workflows/{name}.md` with flow diagram, node config, parsed fields, edge cases, and observability
2. **Build** — construct workflow in n8n UI (or via MCP) following the doc
3. **Test** — run each node step by step, verify output matches doc
4. **Sync** — push to Git via n8n Source Control (Settings → Source Control → Push)

### Source Control
n8n has built-in Git sync (`N8N_VERSION_CONTROL_ENABLED=true`):
- **Dev**: edit in UI → Push to Git
- **Prod**: Pull from Git → workflows deployed
- Setup: Settings → Source Control → connect SSH key to repo

### MCP Integration
AI assistant (Claude Code) connects to n8n via MCP server for:
- Creating and updating workflows programmatically
- Checking workflow executions and errors
- Accessing n8n node documentation

### Structure
```
job-hunter-n8n/
├── docker-compose.yml      # n8n + PostgreSQL (local dev)
├── .env                    # Secrets (gitignored)
├── .env.example
├── docs/
│   └── workflows/          # Workflow design docs (source of truth)
├── scripts/
│   ├── export.sh           # Export workflows from n8n to JSON
│   └── import.sh           # Import workflows from JSON to n8n
├── workflows/              # Workflow JSON exports (version-controlled)
├── CLAUDE.md
└── README.md
```

### Workflow Conventions
- One platform = one scraper workflow
- Shared sub-workflows for reusable operations (folder: Shared, tag: `shared`)
- Scraper workflows in folder: Scrapers
- Schedule Trigger: every 15 minutes
- Output: normalized JSON with job data
- **Sub-workflows handle their own error logging** — Format Error → Telegram Notify → Throw
- **Scraper only logs its own direct HTTP errors** (e.g., RSS fetch)
- **Telegram Notify** — shared sub-workflow, input: `{level: "error"|"warn"|"info", message: "text"}`
- **Send Jobs** — shared sub-workflow, handles has-jobs check + POST + all logging
- **Get Criteria** — shared sub-workflow, handles GET + error logging

### Deployment
- Local: `docker compose up -d`
- Production: Helm chart in smhomelab/deploy, ArgoCD
- Credentials are re-created manually on each instance
