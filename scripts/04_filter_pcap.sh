#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RESULTS_DIR="results"
PCAP_RAW="$RESULTS_DIR/cve5g_internal_benign.pcap"
PCAP_FILTERED="$RESULTS_DIR/cve5g_internal_benign_filtrado.pcap"

if [[ ! -f "$PCAP_RAW" ]]; then
  echo "Arquivo não encontrado: $PCAP_RAW"
  echo "Execute primeiro scripts/02_generate_benign.sh"
  exit 1
fi

echo "Filtrando HTTP/2, NGAP e PFCP..."
tshark -r "$PCAP_RAW" -Y "http2 or ngap or pfcp" -w "$PCAP_FILTERED"

echo "PCAP filtrado em: $PCAP_FILTERED"
