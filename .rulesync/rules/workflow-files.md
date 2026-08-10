---
root: false
globs:
  - 'docs/workflows/**/*.md'
  - 'workflows/**/*.json'
  - 'scripts/export.sh'
  - 'scripts/deploy.sh'
  - 'scripts/import.sh'
  - 'scripts/normalize.jq'
---
# Workflow files

- One platform maps to one scraper workflow tagged `scraper`; scheduled scrapers run
  every 15 minutes unless their design document states otherwise.
- Reusable behavior belongs in a shared sub-workflow tagged `shared`.
- Every shared workflow accepts `source` so logs identify the caller.
- Shared contracts are Get Criteria `{source}`, Send Jobs `{body, count, source}`,
  Telegram Notify `{level, message, source}`, Get Proxies, and Check URLs
  `{urls, source}`. Keep complete I/O details in `docs/workflows/`.
- Check current endpoint schemas and enums against the local Job Hunter OpenAPI spec
  at `http://localhost:8095/api-docs`.
- Shared sub-workflows own their error logging: Format Error -> Telegram Notify ->
  Throw. A scraper logs only its direct HTTP failures.
- `scripts/normalize.jq` is the single canonical representation used by export and
  deploy. Change both lifecycle paths together when its contract changes.
- Export rebuilds `workflows/` completely. Review deletions and renames as carefully as
  modifications.
- Deploy matches workflows by name, remaps environment-specific IDs, and must preserve
  the drift guard.
