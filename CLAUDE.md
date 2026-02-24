# job-hunter-n8n

**TL;DR:** n8n scraping workflows for [Job Hunter](https://github.com/mshykhov/job-hunter). Collects vacancies from DOU, Djinni, Indeed and sends them to the API via REST.

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
- **Workflows are config, not code.** Edit in n8n UI, export as JSON
- **Never edit JSON manually** — only via n8n UI → export
- **No secrets in code** — API keys, tokens via .env (gitignored) or n8n credentials UI
- **N8N_ENCRYPTION_KEY** — one key across all environments. Without it, credentials can't be decrypted

### Structure
```
job-hunter-n8n/
├── docker-compose.yml      # n8n + PostgreSQL (local dev)
├── .env                    # Secrets (gitignored)
├── .env.example
├── workflows/              # Exported workflow JSONs
├── scripts/
│   ├── export.sh           # n8n → Git
│   └── import.sh           # Git → n8n
├── CLAUDE.md
└── README.md
```

### Development Cycle
```
1. docker compose up -d
2. Open http://localhost:5678
3. Edit workflows in UI
4. ./scripts/export.sh
5. git add workflows/ && git commit
```

### Workflow Conventions
- One platform = one workflow
- Each workflow sends POST to job-hunter-api `/api/jobs/ingest`
- Schedule Trigger: every 2 hours
- Output: normalized JSON with job data

### Deployment
- Local: `docker compose up -d`
- Production: Helm chart in smhomelab/deploy, ArgoCD
- Credentials are re-created manually on each instance
