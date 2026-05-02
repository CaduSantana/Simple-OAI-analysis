#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/." && pwd)"

echo "=== Iniciando Pipeline Automático ==="

"$ROOT_DIR/scripts/00_preflight.sh"
"$ROOT_DIR/scripts/01_bootstrap.sh"
CVE_METHOD=ueransim sudo -E "$ROOT_DIR/scripts/03_generate_traffic.sh"
"$ROOT_DIR/scripts/05_shutdown.sh"

echo "Pipeline concluída. Dataset gerado com sucesso em $ROOT_DIR/results/mixed/"