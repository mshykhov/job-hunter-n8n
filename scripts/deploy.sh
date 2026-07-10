#!/bin/bash
# Deploy n8n workflows to production via REST API.
# Matches by name (not file ID), remaps sub-workflow and credential references,
# syncs tags, and refuses to overwrite prod state that was never exported to git
# (drift-guard; override with FORCE=1).
#
# Required env: N8N_URL, N8N_KEY, TELEGRAM_BOT_TOKEN
set -euo pipefail

API="$N8N_URL/api/v1"
NORMALIZE="scripts/normalize.jq"

api() { curl -s -H "X-N8N-API-KEY: $N8N_KEY" -H "Content-Type: application/json" "$@"; }
sha() { openssl dgst -sha256 | awk '{print $NF}'; }

# Helper: build JSON object from key\tvalue lines
kv_to_json() { jq -Rn '[inputs | split("\t") | {(.[0]): .[1]}] | add // {}'; }

# --- Map workflow names to prod IDs ---
echo "=== Mapping workflow IDs ==="
declare -A PROD_ID
declare -A LOCAL_TO_PROD

while IFS=$'\t' read -r name id; do
  PROD_ID["$name"]=$id
done < <(api "$API/workflows?limit=200" | jq -r '.data[] | [.name, .id] | @tsv')

for f in workflows/*.json; do
  lid=$(jq -r '.id // empty' "$f")
  name=$(jq -r '.name' "$f")
  pid=${PROD_ID[$name]:-}
  if [ -n "$pid" ]; then
    if [ -n "$lid" ] && [ "$lid" != "$pid" ]; then LOCAL_TO_PROD[$lid]=$pid; fi
    echo "  $name: ${lid:-?} -> $pid"
  else
    echo "  $name: new"
  fi
done

REMAP=$(for k in "${!LOCAL_TO_PROD[@]}"; do printf '%s\t%s\n' "$k" "${LOCAL_TO_PROD[$k]}"; done | kv_to_json)

# --- Drift-guard ---
# Prod state must be reproducible from the git history of each workflow file.
# If prod was edited (UI/MCP) and never exported, abort instead of reverting it.
echo -e "\n=== Drift check ==="
drifted=()
for f in workflows/*.json; do
  name=$(jq -r '.name' "$f")
  pid=${PROD_ID[$name]:-}
  if [ -z "$pid" ]; then continue; fi

  prod_hash=$(api "$API/workflows/$pid" | jq -S -f "$NORMALIZE" | sha)
  match=0
  while read -r rev; do
    h=$(git show "$rev:$f" 2>/dev/null | jq -S -f "$NORMALIZE" 2>/dev/null | sha) || continue
    if [ "$h" = "$prod_hash" ]; then
      match=1
      break
    fi
  done < <(git log --format=%H -- "$f")

  if [ "$match" -eq 1 ]; then
    echo "  ok: $name"
  else
    drifted+=("$name")
    echo "  DRIFT: $name"
  fi
done

if [ "${#drifted[@]}" -gt 0 ]; then
  if [ "${FORCE:-0}" = "1" ]; then
    echo "  FORCE=1 set - overwriting drifted workflows"
  else
    echo -e "\nAborting: prod has changes not in git history for: ${drifted[*]}"
    echo "Run scripts/export.sh + commit to resync, or re-run with FORCE=1 to overwrite prod."
    exit 1
  fi
fi

# --- Sync credentials ---
echo -e "\n=== Syncing credentials ==="
declare -A CRED_ID

while IFS=$'\t' read -r name id; do
  CRED_ID["$name"]=$id
done < <(api "$API/credentials?limit=200" | jq -r '.data[] | [.name, .id] | @tsv')

# Sync Telegram Bot credential
cred_data='{"name":"Telegram Bot","type":"telegramApi","data":{"accessToken":"'"$TELEGRAM_BOT_TOKEN"'","baseUrl":"https://api.telegram.org"}}'
if [ -n "${CRED_ID["Telegram Bot"]:-}" ]; then
  api -X PATCH "$API/credentials/${CRED_ID["Telegram Bot"]}" -d "$cred_data" > /dev/null
  echo "  Telegram Bot: updated (${CRED_ID["Telegram Bot"]})"
else
  cid=$(api -X POST "$API/credentials" -d "$cred_data" | jq -r '.id')
  CRED_ID["Telegram Bot"]=$cid
  echo "  Telegram Bot: created ($cid)"
fi

echo -e "\n=== Mapping credential IDs ==="

# Build local credential ID -> prod ID map from workflow files
declare -A CRED_REMAP
for f in workflows/*.json; do
  while IFS=$'\t' read -r lid cname; do
    pid=${CRED_ID[$cname]:-}
    [ -n "$pid" ] && [ "$lid" != "$pid" ] && CRED_REMAP[$lid]=$pid
  done < <(jq -r '[.nodes[].credentials // {} | to_entries[]] | unique_by(.value.id) | .[] | [.value.id, .value.name] | @tsv' "$f")
done

CRED_MAP=$(for k in "${!CRED_REMAP[@]}"; do printf '%s\t%s\n' "$k" "${CRED_REMAP[$k]}"; done | kv_to_json)
for k in "${!CRED_REMAP[@]}"; do echo "  remap: $k -> ${CRED_REMAP[$k]}"; done

# --- Sync tags ---
echo -e "\n=== Syncing tags ==="
declare -A TAG_ID

while IFS=$'\t' read -r name id; do
  TAG_ID["$name"]=$id
done < <(api "$API/tags?limit=100" | jq -r '.data[] | [.name, .id] | @tsv')

for tag in $(jq -r '.tags[]?.name // empty' workflows/*.json | sort -u); do
  if [ -z "${TAG_ID[$tag]:-}" ]; then
    TAG_ID[$tag]=$(api -X POST "$API/tags" -d "{\"name\":\"$tag\"}" | jq -r '.id')
    echo "  Created: $tag (${TAG_ID[$tag]})"
  else
    echo "  Exists: $tag (${TAG_ID[$tag]})"
  fi
done

TAG_MAP=$(for k in "${!TAG_ID[@]}"; do printf '%s\t%s\n' "$k" "${TAG_ID[$k]}"; done | kv_to_json)

# --- Deploy workflows ---
echo -e "\n=== Deploying ==="
failed=0

for f in workflows/*.json; do
  name=$(jq -r '.name' "$f")
  pid=${PROD_ID[$name]:-}

  # Normalize to API fields + remap sub-workflow and credential IDs (local -> prod)
  payload=$(jq -S -f "$NORMALIZE" "$f" | jq --argjson remap "$REMAP" --argjson cremap "$CRED_MAP" '
    del(.id, .tags)
    | .nodes |= [.[] |
      if .parameters.workflowId?.value? then
        .parameters.workflowId.value = ($remap[.parameters.workflowId.value] // .parameters.workflowId.value)
      else . end |
      if .credentials then
        .credentials |= with_entries(.value.id = ($cremap[.value.id] // .value.id))
      else . end
    ]')

  if [ -n "$pid" ]; then
    if ! echo "$payload" | api -f -X PUT "$API/workflows/$pid" -d @- > /dev/null; then
      echo "  FAILED: $name (PUT $pid)"; failed=1; continue
    fi
    echo "  $name -> updated ($pid)"
  else
    response=$(echo "$payload" | api -X POST "$API/workflows" -d @-)
    pid=$(echo "$response" | jq -r '.id // empty')
    if [ -z "$pid" ]; then
      echo "  FAILED: $name (POST)"; failed=1; continue
    fi
    PROD_ID[$name]=$pid
    echo "  $name -> created ($pid)"
  fi

  # Sync tags via jq (map tag names to prod IDs)
  tags=$(jq --argjson tm "$TAG_MAP" \
    '[.tags[]?.name // empty | {id: $tm[.]}] | map(select(.id))' "$f")
  [ "$tags" != "[]" ] && api -X PUT "$API/workflows/$pid/tags" -d "$tags" > /dev/null

  # Active state is managed per-environment, not synced from git
done

[ "$failed" -eq 1 ] && exit 1
echo -e "\n=== Done ==="
