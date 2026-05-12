#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REMOTE_USER="${REMOTE_USER:-}"
REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_BASE="${REMOTE_BASE:-~/oai}"

if [[ -z "$REMOTE_USER" || -z "$REMOTE_HOST" ]]; then
  echo "Set REMOTE_USER and REMOTE_HOST before running."
  echo "Example: REMOTE_USER=ubuntu REMOTE_HOST=10.0.0.10 $0"
  exit 1
fi

rsync -avz --delete \
  --exclude '.git' \
  --exclude 'cn/results/*.pcap' \
  "$ROOT_DIR/" \
  "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_BASE}/oai-workshops/"

echo "Sync completed to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_BASE}/oai-workshops/"