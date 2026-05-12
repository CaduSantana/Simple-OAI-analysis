#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SCENARIO="${SCENARIO:-2}"
CVE_METHOD="${CVE_METHOD:-python}"

echo "=== Starting Automatic Pipeline (Scenario ${SCENARIO}) ==="

"$ROOT_DIR/scripts/00_preflight.sh"
"$ROOT_DIR/scripts/01_bootstrap.sh"

echo "Waiting an additional 15 seconds for radio signal stabilization..."
sleep 15

SCENARIO="$SCENARIO" CVE_METHOD="$CVE_METHOD" sudo -E "$ROOT_DIR/scripts/02_generate_traffic.sh"

"$ROOT_DIR/scripts/03_shutdown.sh"

echo "=== Pipeline completed ==="
echo "Dataset successfully generated at: $ROOT_DIR/results/scenario_${SCENARIO}/"