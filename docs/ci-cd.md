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
| `N8N_API_URL` | GitHub Secrets | Prod n8n base URL (e.g., `https://job-hunt-n8n-prd.trout-paradise.ts.net`) |
| `N8N_API_KEY` | GitHub Secrets | n8n API authentication |
| ACL tag `tag:ci` | Tailscale ACL | Allow GHA runner to reach n8n |

## GitHub Actions Workflow

**File:** `.github/workflows/deploy.yml` (in job-hunter-n8n repo)

See the actual file for implementation. Key features:
- Matches workflows by **name** (not file ID) — handles local/prod ID mismatch
- Remaps sub-workflow references (`executeWorkflow` node IDs) from local to prod
- Syncs tags: creates missing tags on prod, assigns to workflows
- Handles new workflows via POST, existing via PUT
- Activates workflows that were active locally
- Fails the pipeline if any workflow deployment fails

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
      "dst": ["tag:k8s:443"]
    }
  ]
}
```

`tag:k8s` is the tag on the `ingress-proxies` ProxyGroup. Port 443 because
Tailscale Ingress terminates TLS (n8n ClusterIP:5678 is internal only).

## API Behavior: Auto-Publish on PUT

Exported JSON contains `"active": true` for all running workflows. When the pipeline does
`PUT /api/v1/workflows/{id}` with this JSON:

- Workflow nodes, connections, and settings are **replaced immediately**
- `active: true` is preserved — triggers re-register with updated logic
- Changes are **live instantly** (no separate "publish" step via API)

**Caveat:** If a workflow was manually deactivated on prod (e.g., for debugging), the deploy
will **re-activate it** because the JSON has `"active": true`. To avoid this, the deploy script
should GET the current prod status first and preserve the original `active` value during PUT.

## ID Remapping

Local and prod n8n instances assign different IDs to the same workflows. The pipeline handles
this automatically:

1. **Matches by name** — fetches all prod workflows, builds a `name → prod_id` map
2. **Remaps sub-workflow references** — `executeWorkflow` nodes reference sub-workflows by ID.
   The pipeline replaces local IDs with prod IDs in the payload before deploying
3. **New workflows** — if no matching name found on prod, creates via POST and captures the new ID

Workflow JSON filenames can use either local or prod IDs — the pipeline ignores filenames and
relies entirely on the `name` field for matching.

## Limitations

- **One-way sync** — dev → prod only. No pull-back from prod
- **No diff preview** — deploys all changed files. Review changes in PR before merge
- **Credentials not synced** — managed separately per environment
- **Active status override** — see "Auto-Publish on PUT" section above
- **Name-based matching** — workflows are matched by name, so names must be unique

## TODO

- [x] Configure Tailscale OAuth client
- [x] Add GitHub Secrets to job-hunter-n8n repo
- [x] Create n8n API key on prod
- [x] Set up Tailscale ACL for `tag:ci`
- [x] Create `.github/workflows/deploy.yml`
- [x] Handle new workflow creation (POST vs PUT logic)
- [x] Test end-to-end deployment
