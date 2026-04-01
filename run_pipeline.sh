#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT_DIR/scripts/01_bootstrap.sh"
"$ROOT_DIR/scripts/02_generate_benign.sh"
"$ROOT_DIR/scripts/03_filter_pcap.sh"
"$ROOT_DIR/scripts/04_shutdown.sh"

echo "Pipeline concluída. Arquivos em $ROOT_DIR/results"
