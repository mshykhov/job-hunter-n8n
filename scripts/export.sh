#!/bin/bash
# Export all workflows from an n8n instance into workflows/ as slug-named,
# normalized JSON (see normalize.jq). The instance is the source of truth;
# run this after editing workflows in the UI or via MCP, then commit.
#
# Required env: N8N_URL, N8N_KEY (falls back to .env in the repo root)
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$DIR/workflows"

if [ -z "${N8N_URL:-}" ] && [ -f "$DIR/.env" ]; then
  N8N_URL=$(grep -E '^N8N_URL=' "$DIR/.env" | head -1 | cut -d= -f2-)
fi
if [ -z "${N8N_KEY:-}" ] && [ -f "$DIR/.env" ]; then
  N8N_KEY=$(grep -E '^N8N_KEY=' "$DIR/.env" | head -1 | cut -d= -f2-)
fi
: "${N8N_URL:?N8N_URL is required}" "${N8N_KEY:?N8N_KEY is required}"

API="$N8N_URL/api/v1"
api() { curl -sf -H "X-N8N-API-KEY: $N8N_KEY" "$@"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Fetch every workflow (cursor pagination) before touching workflows/
page=0
cursor=""
while :; do
  url="$API/workflows?limit=100"
  if [ -n "$cursor" ]; then url="$url&cursor=$cursor"; fi
  api "$url" > "$TMP/page$page.json"
  cursor=$(jq -r '.nextCursor // empty' "$TMP/page$page.json")
  if [ -z "$cursor" ]; then break; fi
  page=$((page + 1))
done
jq -s '[.[].data[]]' "$TMP"/page*.json > "$TMP/all.json"
count=$(jq 'length' "$TMP/all.json")

# Rebuild workflows/ from scratch so renames and deletions show up in git
mkdir -p "$OUT"
find "$OUT" -name '*.json' -delete

for i in $(seq 0 $((count - 1))); do
  name=$(jq -r ".[$i].name" "$TMP/all.json")
  slug=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g' | sed -E 's/^-+|-+$//g')
  file="$OUT/$slug.json"
  if [ -e "$file" ]; then
    echo "ERROR: duplicate slug '$slug' (workflow name collision: $name)" >&2
    exit 1
  fi
  jq -S ".[$i]" "$TMP/all.json" | jq -S -f "$DIR/scripts/normalize.jq" > "$file"
  echo "  $name -> workflows/$slug.json"
done

echo "Exported $count workflows from $N8N_URL"
