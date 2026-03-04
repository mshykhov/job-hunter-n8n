#!/bin/bash
# Export all workflows from running n8n container to workflows/ directory
set -e

CONTAINER="job-hunter-n8n"
EXPORT_DIR="/home/node/.n8n/exports"
LOCAL_DIR="$(dirname "$0")/../workflows"

docker exec "$CONTAINER" rm -rf "$EXPORT_DIR"
docker exec "$CONTAINER" mkdir -p "$EXPORT_DIR"
docker exec "$CONTAINER" n8n export:workflow --all --separate --output="$EXPORT_DIR"
mkdir -p "$LOCAL_DIR"
docker exec "$CONTAINER" tar cf - -C "$EXPORT_DIR" . | tar xf - -C "$LOCAL_DIR"

# Strip instance-specific fields (active status, runtime state)
for f in "$LOCAL_DIR"/*.json; do
  python3 -c "
import json, sys
wf = json.loads(open(sys.argv[1]).read())
for key in ['active', 'staticData']:
    wf.pop(key, None)
open(sys.argv[1], 'w').write(json.dumps(wf))
" "$f"
done

echo "Exported $(ls "$LOCAL_DIR"/*.json 2>/dev/null | wc -l) workflows"
