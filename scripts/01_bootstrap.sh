#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

host_arch="$(uname -m)"
if [[ "$host_arch" != "x86_64" ]]; then
	echo "[aviso] Host detectado: $host_arch"
	echo "[aviso] A RAN (oai-gnb/oai-nr-ue1) requer Linux x86_64 para funcionar corretamente."
	echo "[aviso] O Core 5G será iniciado; a RAN pode falhar com 'Illegal instruction'."
fi

mkdir -p results
chmod 777 results

echo "[1/4] Subindo banco (mysql)..."
docker compose -f docker-compose.yml up -d mysql

echo "[2/4] Subindo Core 5G..."
docker compose -f docker-compose.yml up -d

echo "[3/4] Aguardando estabilização inicial..."
sleep 15

echo "[4/4] Subindo RAN (gNB + UE)..."
docker compose -f docker-compose-ran.yml up -d oai-gnb oai-nr-ue1

sleep 3
gnb_status="$(docker inspect -f '{{.State.Status}}' oai-gnb 2>/dev/null || true)"
ue_status="$(docker inspect -f '{{.State.Status}}' oai-nr-ue1 2>/dev/null || true)"

if [[ "$gnb_status" != "running" || "$ue_status" != "running" ]]; then
	echo "[erro] RAN não permaneceu ativa."
	echo "[erro] status oai-gnb: ${gnb_status:-desconhecido}"
	echo "[erro] status oai-nr-ue1: ${ue_status:-desconhecido}"
	echo "[dica] Em host ARM/macOS, execute a RAN em Linux x86_64."
	exit 1
fi

echo "Infraestrutura inicializada com sucesso."
