#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "Desligando gNB e UE..."
docker compose -f docker-compose-ran.yml down

echo "Desligando Core 5G..."
docker compose -f docker-compose.yml down

echo "Ambiente finalizado."
