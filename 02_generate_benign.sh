#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RESULTS_DIR="results"
PCAP_RAW="$RESULTS_DIR/cve5g_internal_benign.pcap"
TSHARK_PID_FILE="$RESULTS_DIR/tshark.pid"
DN_IP="192.168.70.135"
UE_BIND_IP="${UE_BIND_IP:-10.0.0.2}"
SUDO_PASSWORD="${SUDO_PASSWORD:-}"

mkdir -p "$RESULTS_DIR"

sudo_run() {
  if [[ -n "$SUDO_PASSWORD" ]]; then
    printf '%s\n' "$SUDO_PASSWORD" | sudo -S -p '' "$@"
  else
    sudo "$@"
  fi
}

if ! command -v tshark >/dev/null 2>&1; then
  echo "tshark não encontrado no host. Instale antes de continuar."
  exit 1
fi

container_status() {
  docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || true
}

if [[ "$(container_status oai-ext-dn)" != "running" ]]; then
  echo "Container oai-ext-dn não está ativo. Execute scripts/01_bootstrap.sh primeiro."
  exit 1
fi

if [[ "$(container_status oai-nr-ue1)" != "running" ]]; then
  echo "Container oai-nr-ue1 não está ativo."
  echo "A geração de tráfego benigno exige RAN funcional em Linux x86_64."
  exit 1
fi

cleanup_capture() {
  if [[ -f "$TSHARK_PID_FILE" ]]; then
    local pid
    pid="$(cat "$TSHARK_PID_FILE")"
    if [[ -n "${pid}" ]] && kill -0 "$pid" 2>/dev/null; then
      sudo_run kill "$pid" || true
    fi
    rm -f "$TSHARK_PID_FILE"
  fi
}

trap cleanup_capture EXIT

echo "[1/6] Iniciando captura na interface oaiworkshop..."
sudo_run tshark -i oaiworkshop -w "$PCAP_RAW" >/tmp/tshark_oai.log 2>&1 &
echo $! > "$TSHARK_PID_FILE"
sleep 3

echo "[2/6] Subindo servidor iperf3 no DN (oai-ext-dn)..."
docker exec -d oai-ext-dn iperf3 -s || true

echo "[3/6] Gerando tráfego TCP (download HD) por 60s..."
docker exec oai-nr-ue1 iperf3 -B "$UE_BIND_IP" -c "$DN_IP" -R -t 60

echo "[4/6] Gerando tráfego UDP (VoIP/áudio) por 60s..."
docker exec oai-nr-ue1 iperf3 -B "$UE_BIND_IP" -c "$DN_IP" -u -b 2M -t 60

echo "[5/6] Encerrando captura..."
cleanup_capture

echo "[6/6] Ajustando permissões do PCAP..."
sudo_run chown "$USER":"$(id -gn)" "$PCAP_RAW" || true

trap - EXIT
echo "Tráfego benigno gerado em: $PCAP_RAW"
