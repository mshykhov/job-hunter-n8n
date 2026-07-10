# CI/CD: Workflow Deployment

Automated deployment of n8n workflows from Git to production via GitHub Actions + n8n REST API.

## Overview

```
n8n UI/MCP edit → scripts/export.sh → git push → GitHub Actions → scripts/deploy.sh → Prod
```

n8n Community Edition has no built-in Source Control (Enterprise feature).
This pipeline replaces it with a standard CI/CD approach: the n8n instance is
where workflows are edited, git is where they are versioned and reviewed.

## Architecture

```
Developer              GitHub                     Prod K8s (Tailscale)
─────────              ──────                     ────────────────────
Edit in n8n UI/MCP
       │
scripts/export.sh  ◀──────────────────────────  GET /api/v1/workflows
       │
  git commit + push
       │
       └──────────▶  n8n/workflows/*.json
                           │
                     GH Actions triggers
                     (on push, paths filter)
                           │
                     Tailscale connect ──────▶  n8n REST API
                           │                    drift check, then
                     scripts/deploy.sh ──────▶  PUT/POST per workflow ✓
```

## Scripts

| Script | Direction | Purpose |
|--------|-----------|---------|
| `scripts/export.sh` | instance → git | Fetch all workflows (cursor pagination), normalize, write `workflows/<name-slug>.json` |
| `scripts/deploy.sh` | git → instance | Drift check, sync credentials/tags, PUT existing / POST new workflows |
| `scripts/normalize.jq` | shared | Canonical form: `{id, name, nodes, connections, settings subset, sorted tags}`; strips runtime noise (`active`, `staticData`, `versionId`, ...) |

Both scripts take `N8N_URL` + `N8N_KEY` env vars and work against any instance
(prod, local docker). `deploy.sh` additionally needs `TELEGRAM_BOT_TOKEN`.

## Drift-Guard

Before overwriting an existing prod workflow, `deploy.sh` verifies that the
current prod state is reproducible from the git history of that workflow file
(normalized hash comparison across all committed revisions). If prod was edited
in the UI/MCP and never exported, the deploy **aborts** instead of silently
reverting live logic. Recover by running `export.sh` + commit, or force with
`FORCE=1`. This requires full clone history (`fetch-depth: 0` in CI).

## Workflow File Convention

- **Location:** `n8n/workflows/{name-slug}.json` (e.g., `djinni-scraper.json`)
- **Content:** normalized workflow JSON; the `id` field holds the source-instance ID
- **Matching:** deploy matches by the `name` field, never by filename or ID, so
  names must be unique per instance

## Daily Flow

1. Edit workflow in the n8n UI (or via MCP)
2. `N8N_URL=... N8N_KEY=... scripts/export.sh`
3. `git add`, `git commit`, `git push`
4. GitHub Actions deploys - a no-op when prod already matches git

## Prerequisites

| Item | Where | Purpose |
|------|-------|---------|
| n8n API key | Prod n8n → Settings → API | Authenticate API calls |
| Tailscale OAuth client | [Tailscale Admin](https://login.tailscale.com/admin/settings/oauth) | GHA runner joins tailnet |
| `TS_OAUTH_CLIENT_ID` | GitHub Secrets | Tailscale auth |
| `TS_OAUTH_SECRET` | GitHub Secrets | Tailscale auth |
| `N8N_API_URL` | GitHub Secrets | Prod n8n base URL (e.g., `https://job-hunt-n8n-prd.trout-paradise.ts.net`) |
| `N8N_API_KEY` | GitHub Secrets | n8n API authentication |
| ACL tag `tag:ci` | Tailscale ACL | Allow GHA runner to reach n8n |

## Tailscale ACL Setup

Add to Tailscale ACL policy:

```json
{
  "tagOwners": {
    "tag:ci": ["autogroup:admin"]
  },
  "acls": [
    {
      "action": "accept",
      "src": ["tag:ci"],
      "dst": ["tag:k8s:443"]
    }
  ]
}
```

`tag:k8s` is the tag on the `ingress-proxies` ProxyGroup. Port 443 because
Tailscale Ingress terminates TLS (n8n ClusterIP:5678 is internal only).

## Sync Semantics

- **Changes are live instantly** - PUT replaces nodes/connections/settings and
  active workflows re-register their triggers with the updated logic
- **Active state is never synced** - the payload carries no `active` field, so
  a workflow paused on prod stays paused after a deploy
- **Credentials are not synced from files** - deploy.sh creates/updates them
  from env (e.g., Telegram Bot token) and remaps credential IDs by name
- **ID remapping** - `executeWorkflow` node references are translated from the
  file's `id` fields to the target instance's IDs via the name match
