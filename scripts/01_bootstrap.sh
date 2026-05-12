#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

host_arch="$(uname -m)"
if [[ "$host_arch" != "x86_64" ]]; then
	echo "[warning] Detected host: $host_arch"
	echo "[warning] The RAN (oai-gnb/oai-nr-ue1) requires Linux x86_64 to function properly."
	echo "[warning] The 5G Core will start, but the RAN may fail with 'Illegal instruction'."
fi

mkdir -p results
chmod 777 results

echo "[1/4] Starting database (mysql)..."
docker compose -f docker-compose.yml up -d mysql

echo "[2/4] Starting 5G Core..."
docker compose -f docker-compose.yml up -d

echo "[3/4] Waiting for initial stabilization..."
sleep 15

echo "[4/4] Starting RAN (gNB + UE)..."
docker compose -f docker-compose-ran.yml up -d oai-gnb oai-nr-ue1

sleep 3
gnb_status="$(docker inspect -f '{{.State.Status}}' oai-gnb 2>/dev/null || true)"
ue_status="$(docker inspect -f '{{.State.Status}}' oai-nr-ue1 2>/dev/null || true)"

if [[ "$gnb_status" != "running" || "$ue_status" != "running" ]]; then
	echo "[error] RAN did not remain active."
	echo "[error] oai-gnb status: ${gnb_status:-unknown}"
	echo "[error] oai-nr-ue1 status: ${ue_status:-unknown}"
	echo "[tip] On ARM/macOS hosts, run the RAN on Linux x86_64."
	exit 1
fi

echo "Infrastructure initialized successfully."