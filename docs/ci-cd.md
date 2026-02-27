# CI/CD: Workflow Deployment

Automated deployment of n8n workflows from Git to production via GitHub Actions + n8n REST API.

## Overview

```
Dev n8n UI → export JSON → git push → GitHub Actions → n8n API → Prod updated
```

n8n Community Edition has no built-in Source Control (Enterprise feature).
This pipeline replaces it with a standard CI/CD approach.

## Architecture

```
Developer              GitHub                     Prod K8s (Tailscale)
─────────              ──────                     ────────────────────
Edit in dev n8n UI
       │
Export workflow JSON
       │
  git commit + push
       │
       └──────────▶  n8n/workflows/*.json
                           │
                     GH Actions triggers
                     (on push, paths filter)
                           │
                     Tailscale connect ──────▶  n8n REST API
                           │                    PUT /api/v1/workflows/{id}
                     For each .json ─────────▶  Workflow updated ✓
```

## Prerequisites

| Item | Where | Purpose |
|------|-------|---------|
| n8n API key | Prod n8n → Settings → API | Authenticate API calls |
| Tailscale OAuth client | [Tailscale Admin](https://login.tailscale.com/admin/settings/oauth) | GHA runner joins tailnet |
| `TS_OAUTH_CLIENT_ID` | GitHub Secrets | Tailscale auth |
| `TS_OAUTH_SECRET` | GitHub Secrets | Tailscale auth |
| `N8N_API_URL` | GitHub Secrets | Prod n8n base URL (e.g., `http://n8n.tailnet:5678`) |
| `N8N_API_KEY` | GitHub Secrets | n8n API authentication |
| ACL tag `tag:ci` | Tailscale ACL | Allow GHA runner to reach n8n |

## GitHub Actions Workflow

**File:** `.github/workflows/deploy-n8n.yml` (in monorepo root)

```yaml
name: Deploy n8n workflows

on:
  push:
    paths:
      - 'n8n/workflows/**'
    branches: [master]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: true

      - uses: tailscale/github-action@v3
        with:
          oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
          oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
          tags: tag:ci

      - name: Deploy workflows to prod n8n
        env:
          N8N_URL: ${{ secrets.N8N_API_URL }}
          N8N_KEY: ${{ secrets.N8N_API_KEY }}
        run: |
          for file in n8n/workflows/*.json; do
            ID=$(basename "$file" .json)
            echo "Deploying workflow $ID..."

            STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
              "$N8N_URL/api/v1/workflows/$ID" \
              -H "X-N8N-API-KEY: $N8N_KEY" \
              -H "Content-Type: application/json" \
              -d @"$file")

            if [ "$STATUS" -ge 200 ] && [ "$STATUS" -lt 300 ]; then
              echo "  ✓ deployed (HTTP $STATUS)"
            else
              echo "  ✗ failed (HTTP $STATUS)"
              exit 1
            fi
          done
```

## Workflow File Convention

- **Location:** `n8n/workflows/{workflow-id}.json`
- **Filename** = n8n workflow ID (e.g., `F6YhykBr7ADDUxk1.json`)
- **Format:** Full workflow JSON as exported from n8n API `GET /api/v1/workflows/{id}`

## Daily Flow

1. Edit workflow in **dev** n8n UI
2. Export updated JSON to `n8n/workflows/` (via MCP or n8n API)
3. `git add`, `git commit`, `git push`
4. GitHub Actions auto-deploys to prod

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
      "dst": ["tag:k8s:5678"]
    }
  ]
}
```

Adjust `dst` to match your prod n8n node/tag.

## Limitations

- **One-way sync** — dev → prod only. No pull-back from prod
- **No diff preview** — deploys all changed files. Review changes in PR before merge
- **Credentials not synced** — managed separately per environment
- **New workflows** — if a workflow ID doesn't exist in prod, the PUT will fail. Create it manually first or use POST for new IDs

## TODO

- [ ] Configure Tailscale OAuth client
- [ ] Add GitHub Secrets to monorepo
- [ ] Create n8n API key on prod
- [ ] Set up Tailscale ACL for `tag:ci`
- [ ] Create and test `.github/workflows/deploy-n8n.yml`
- [ ] Handle new workflow creation (POST vs PUT logic)
