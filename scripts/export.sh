#!/bin/bash
# Export all workflows from running n8n container to workflows/ directory
set -e

CONTAINER="job-hunter-n8n"
EXPORT_DIR="/home/node/.n8n/exports"
LOCAL_DIR="$(dirname "$0")/../workflows"

docker exec "$CONTAINER" rm -rf "$EXPORT_DIR"
docker exec "$CONTAINER" mkdir -p "$EXPORT_DIR"
docker exec "$CONTAINER" n8n export:workflow --all --separate --output="$EXPORT_DIR"
docker cp "$CONTAINER:$EXPORT_DIR/." "$LOCAL_DIR/"

echo "Exported $(ls "$LOCAL_DIR"/*.json 2>/dev/null | wc -l) workflows"
