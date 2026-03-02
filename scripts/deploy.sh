#!/bin/bash
# Deploy n8n workflows to production via REST API.
# Matches by name (not file ID), remaps sub-workflow references, syncs tags.
#
# Required env: N8N_URL, N8N_KEY
set -euo pipefail

API="$N8N_URL/api/v1"

api() { curl -s -H "X-N8N-API-KEY: $N8N_KEY" -H "Content-Type: application/json" "$@"; }

# n8n API accepted fields (active and tags are read-only)
FILTER='{
  name, nodes, connections, staticData,
  settings: (.settings // {} | {
    executionOrder, timezone, callerPolicy, callerIds,
    availableInMCP, saveExecutionProgress, saveManualExecutions,
    saveDataErrorExecution, saveDataSuccessExecution,
    executionTimeout, errorWorkflow, timeSavedPerExecution
  } | with_entries(select(.value != null)))
}'

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
  lid=$(basename "$f" .json)
  name=$(jq -r '.name' "$f")
  pid=${PROD_ID[$name]:-}
  if [ -n "$pid" ]; then
    LOCAL_TO_PROD[$lid]=$pid
    echo "  $name: $lid -> $pid"
  else
    echo "  $name: new"
  fi
done

REMAP=$(for k in "${!LOCAL_TO_PROD[@]}"; do printf '%s\t%s\n' "$k" "${LOCAL_TO_PROD[$k]}"; done | kv_to_json)

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
  active=$(jq -r '.active' "$f")
  pid=${PROD_ID[$name]:-}

  # Filter to API fields + remap sub-workflow IDs (local -> prod)
  payload=$(jq --argjson remap "$REMAP" "$FILTER |
    .nodes |= [.[] | if .parameters.workflowId?.value? then
      .parameters.workflowId.value = (\$remap[.parameters.workflowId.value] // .parameters.workflowId.value)
    else . end]" "$f")

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

  # Activate if was active locally
  [ "$active" = "true" ] && api -X POST "$API/workflows/$pid/activate" > /dev/null && echo "  activated"
done

[ "$failed" -eq 1 ] && exit 1
echo -e "\n=== Done ==="
