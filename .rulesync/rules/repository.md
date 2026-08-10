---
root: true
---
# Job Hunter n8n workflows

n8n workflow repository for collecting vacancies from job platforms and sending
normalized records to the Job Hunter API.

Stack: n8n 2.10 Community, PostgreSQL 16, Docker Compose, shell, and jq.

## Working contract

- Edit workflows in the live editor or through the configured n8n integration.
- Treat `workflows/*.json` as normalized generated exports, not hand-edited source.
- Keep API keys, tokens, and credentials in ignored environment files or secret stores.
- Use one `N8N_ENCRYPTION_KEY` across environments that must read the same credentials.
- Use environment variables for external configuration.
- Keep repository content and commits in English and use Conventional Commits.
- Do not add AI-generation references or attribution trailers to commits.
- Keep only reviewed, production-ready workflows on `master`.

Use the `develop-n8n-workflow` skill whenever creating, changing, debugging,
exporting, or deploying a workflow.

## Repository flow

The live n8n instance is the editing surface. Git is the reviewed, normalized version
history:

1. Design and document intended behavior.
2. Build and test in n8n.
3. Export every workflow through `scripts/export.sh`.
4. Review and commit the normalized diff.
5. Deploy through the drift-guarded pipeline.

Pushing `workflows/**` to `master` triggers deployment. Deployment stops when live
state is not reproducible from Git history. Resynchronize through export and commit;
use `FORCE=1` only with explicit authority to overwrite confirmed live drift.

Active state is environment-specific and is never synchronized from Git.
Production runtime configuration lives in the infrastructure repository and is applied
through ArgoCD. Credentials remain environment-specific; deploy maps them by name and
syncs the Telegram credential from environment values without storing secrets in Git.

## Structure

- `docs/workflows/` is the behavior and observability source of truth.
- `workflows/` contains slug-named normalized JSON exports.
- `scripts/export.sh` snapshots all live workflows.
- `scripts/deploy.sh` maps workflow, credential, and tag IDs and enforces drift.
- `scripts/normalize.jq` defines the tracked representation.
- `scripts/import.sh` loads exports into the local Docker instance.

## Local commands

```sh
docker compose up -d
./scripts/import.sh
npm run rulesync:verify
```

`.rulesync/` is canonical. Generated instruction, rule, and skill files are derived
outputs and must not be edited directly.
