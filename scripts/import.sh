#!/bin/bash
# Import all workflows from workflows/ directory into running n8n container
set -e

CONTAINER="job-hunter-n8n"
IMPORT_DIR="/home/node/.n8n/imports"
LOCAL_DIR="$(dirname "$0")/../workflows"

docker exec "$CONTAINER" rm -rf "$IMPORT_DIR"
docker exec "$CONTAINER" mkdir -p "$IMPORT_DIR"
tar cf - -C "$LOCAL_DIR" --include='*.json' . | docker exec -i "$CONTAINER" tar xf - -C "$IMPORT_DIR"
docker exec "$CONTAINER" n8n import:workflow --separate --input="$IMPORT_DIR"

echo "Import complete"
