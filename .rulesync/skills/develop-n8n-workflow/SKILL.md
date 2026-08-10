---
name: develop-n8n-workflow
description: Use when creating, changing, debugging, exporting, or deploying an n8n scraper or shared workflow in this repository.
---
# Develop an n8n workflow

## Overview

The live n8n instance is the editing surface, documentation defines the intended
behavior, and normalized Git exports provide the reviewable history. Never hand-edit
`workflows/*.json`.

## Preflight

1. Read the repository instructions, the relevant `docs/workflows/{name}.md`, and the
   latest executions.
2. Inspect `git status` and preserve unrelated work.
3. Resolve the exact n8n environment. Authority must name the target environment; a
   request to change it authorizes live editing. Production editing or deploy must be
   explicit and name production.
4. Export current live state. If it differs from Git, stop and commit the resync as a
   separate rollback commit before changing behavior. Never mix inherited drift with
   the functional change. Record `git rev-parse HEAD` as the rollback SHA and do not
   start a live edit until that commit reproduces the export.

## Workflow

1. Update `docs/workflows/{name}.md` first. Record the flow, node configuration,
   parsed fields, contracts, edge cases, error paths, and observability.
2. Build in the live editor or through the configured n8n integration. Follow the
   document and reuse established shared workflows.
3. Test each node in order. Verify normalized output, empty and malformed inputs,
   duplicates, downstream contracts, notifications, and failure paths. Mark a check
   inapplicable only when the workflow document explains why.
4. Run `scripts/export.sh` with `N8N_URL` and `N8N_KEY` supplied through the
   environment. It exports all workflows, normalizes them, and owns filenames.
5. Review the complete diff, including renames and deletions. Validate changed JSON
   with `jq`, run `git diff --check`, and confirm the export matches the document.
6. Commit the document and normalized export together with a Conventional Commit.
7. Deploy only when explicitly requested. Use the established push pipeline or the
   command below, then inspect live executions. If the drift guard fails, export and
   commit live state or stop. `FORCE=1` requires explicit authority to overwrite
   confirmed live changes. To roll back, restore the recorded rollback SHA with a Git
   revert and redeploy it to the same named environment; do not repair export JSON by
   hand.

## Commands

```sh
N8N_URL=https://... N8N_KEY=... ./scripts/export.sh
N8N_URL=https://... N8N_KEY=... TELEGRAM_BOT_TOKEN=... ./scripts/deploy.sh
```

## Common mistakes

| Mistake | Required response |
| --- | --- |
| Editing exported JSON | Revert the edit and make the change in n8n. |
| Building before docs | Stop, update the workflow document, then resume. |
| Basing work on stale Git JSON | Export live state and reconcile drift first. |
| Mixing live drift into the feature commit | Commit the resync separately first. |
| Treating deploy success as verification | Inspect the resulting executions and outputs. |
