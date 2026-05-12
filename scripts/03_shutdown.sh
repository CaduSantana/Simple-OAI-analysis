#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "Shutting down gNB and UE..."
docker compose -f docker-compose-ran.yml down

echo "Shutting down 5G Core..."
docker compose -f docker-compose.yml down

echo "Environment terminated."