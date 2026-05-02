#!/usr/bin/env bash
# =============================================================================
# 05_generate_traffic.sh
# Gera tráfego para o dataset: benigno contínuo + ataques convencionais + CVE
# Duração total: ~300s (5 min)
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# --- Configuração ---------------------------------------------------------
RESULTS_DIR="results/mixed"
PCAP_RAW="$RESULTS_DIR/cve5g_mixed_raw.pcap"
PCAP_FILTERED="$RESULTS_DIR/cve5g_mixed_filtered.pcap"
LABELS_CSV="$RESULTS_DIR/cve5g_labels.csv"
TSHARK_PID_FILE="$RESULTS_DIR/tshark_mixed.pid"

# IPs da topologia
DN_IP="192.168.70.135"       # oai-ext-dn — servidor de dados
AMF_IP="192.168.70.132"      # oai-amf   — alvo dos ataques de DoS
KALI_IP="192.168.70.130"     # oai-attacker (kali, fixado no docker-compose)
UE_BIND_IP="${UE_BIND_IP:-10.0.0.2}"

# Portas do Core 5G
AMF_SBI_PORT=80              # HTTP/2 SBI (NRF↔AMF)
AMF_NGAP_PORT=38412          # SCTP N2 (gNB↔AMF)

SUDO_PASSWORD="${SUDO_PASSWORD:-}"
TOTAL_DURATION=300           # 5 minutos

mkdir -p "$RESULTS_DIR"

# --- Helpers --------------------------------------------------------------
sudo_run() {
  if [[ -n "$SUDO_PASSWORD" ]]; then
    printf '%s\n' "$SUDO_PASSWORD" | sudo -S -p '' "$@"
  else
    sudo "$@"
  fi
}

container_running() {
  [[ "$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null)" == "running" ]]
}

# Tempo relativo em segundos desde T0
elapsed() { echo $(( $(date +%s) - T0 )); }

log() { echo "[$(elapsed)s] $*"; }

# Escreve uma linha no CSV de rótulos
label() {
  local name="$1" src="$2" dst="$3" t_start="$4" t_end="$5"
  echo "$name,$src,$dst,$t_start,$t_end" >> "$LABELS_CSV"
}

# --- Pré-checks -----------------------------------------------------------
for c in oai-ext-dn oai-nr-ue1 oai-attacker; do
  if ! container_running "$c"; then
    echo "[erro] Container $c não está ativo."
    echo "       Execute scripts/01_bootstrap.sh e verifique o docker-compose.yml"
    echo "       (o kali deve estar no docker-compose, não criado em runtime)"
    exit 1
  fi
done

if ! command -v tshark >/dev/null 2>&1; then
  echo "[erro] tshark não encontrado no host."; exit 1
fi

# --- Cleanup --------------------------------------------------------------
cleanup() {
  log "Encerrando processos..."
  if [[ -f "$TSHARK_PID_FILE" ]]; then
    local pid; pid="$(cat "$TSHARK_PID_FILE")"
    if kill -0 "$pid" 2>/dev/null; then
      sudo_run kill "$pid" || true
    fi
    rm -f "$TSHARK_PID_FILE"
  fi
  # Para iperf3 nos containers
  docker exec oai-nr-ue1 pkill iperf3 2>/dev/null || true
  docker exec oai-ext-dn pkill iperf3 2>/dev/null || true
}
trap cleanup EXIT

# --- Início ---------------------------------------------------------------
echo "=== CVE5G — Geração de Dataset Misto (${TOTAL_DURATION}s) ==="

# Inicializar CSV de rótulos
echo "label,src_ip,dst_ip,t_start,t_end" > "$LABELS_CSV"

T0=$(date +%s)

# [T=0] Iniciar captura
log "Iniciando captura na interface oaiworkshop..."
sudo_run tshark -i oaiworkshop -w "$PCAP_RAW" >/tmp/tshark_mixed.log 2>&1 &
echo $! > "$TSHARK_PID_FILE"
sleep 2   # aguarda tshark abrir a interface

# [T=2] Tráfego benigno - sobe servidor e aguarda confirmação
log "Iniciando servidor iperf3 no DN..."
docker exec -d oai-ext-dn iperf3 -s
sleep 2

# Verifica conectividade UE->DN antes de prosseguir
log "Verificando conectividade UE→DN (iperf3 TCP 5s de teste)..."
if ! docker exec oai-nr-ue1 iperf3 -B "$UE_BIND_IP" -c "$DN_IP" -t 5 --connect-timeout 3000 >/dev/null 2>&1; then
  echo "[erro] UE não consegue alcançar o DN. Verifique a sessão PDU (registro do UE)."
  exit 1
fi
log "Conectividade OK. Iniciando streams de vídeo e áudio em background..."

TS_BENIGN=$(elapsed)
# Vídeo HD (TCP download) - dura o experimento inteiro
docker exec -d oai-nr-ue1 iperf3 -B "$UE_BIND_IP" -c "$DN_IP" -R -t "$TOTAL_DURATION" -b 15M
# Áudio/VoIP (UDP) - dura o experimento inteiro
docker exec -d oai-nr-ue1 iperf3 -B "$UE_BIND_IP" -c "$DN_IP" -u -b 2M -t "$TOTAL_DURATION"
label "benign_video_tcp" "$UE_BIND_IP" "$DN_IP" "$TS_BENIGN" "$TOTAL_DURATION"
label "benign_audio_udp"  "$UE_BIND_IP" "$DN_IP" "$TS_BENIGN" "$TOTAL_DURATION"

# Aguarda tráfego benigno fluir por 30s antes dos ataques
log "Tráfego benigno ativo. Aguardando 30s antes dos ataques..."
sleep 30

# ==========================================================================
# ATAQUE 1: Port Scan (Nmap SYN scan)          ~T=40s, ~30s de duração
# ==========================================================================
log "Ataque 1: Port Scan (nmap -sS) → $AMF_IP"
TS=$(elapsed)
docker exec oai-attacker nmap -sS -p 80,38412,8080,2152 -T4 "$AMF_IP" \
  >/tmp/nmap_result.txt 2>&1 || true
TE=$(elapsed)
label "attack_portscan" "$KALI_IP" "$AMF_IP" "$TS" "$TE"
log "Ataque 1 finalizado (${TS}s→${TE}s)."
sleep 10

# ==========================================================================
# ATAQUE 2: TCP SYN Flood        ~T=80s, 30s de duração
# Alvo: porta 80 do SBI (onde o AMF de fato escuta)
# ==========================================================================
log "Ataque 2: TCP SYN Flood → $AMF_IP:$AMF_SBI_PORT"
TS=$(elapsed)
docker exec oai-attacker timeout 30 \
  hping3 -S --flood -p "$AMF_SBI_PORT" "$AMF_IP" >/dev/null 2>&1 || true
TE=$(elapsed)
label "attack_syn_flood" "$KALI_IP" "$AMF_IP" "$TS" "$TE"
log "Ataque 2 finalizado (${TS}s→${TE}s)."
sleep 10

# ==========================================================================
# ATAQUE 3: UDP Flood volumétrico        ~T=120s, 30s de duração
# ==========================================================================
log "Ataque 3: UDP Flood → $AMF_IP:$AMF_SBI_PORT"
TS=$(elapsed)
docker exec oai-attacker timeout 30 \
  hping3 --udp --flood -p "$AMF_SBI_PORT" "$AMF_IP" >/dev/null 2>&1 || true
TE=$(elapsed)
label "attack_udp_flood" "$KALI_IP" "$AMF_IP" "$TS" "$TE"
log "Ataque 3 finalizado (${TS}s→${TE}s)."
sleep 10

# ==========================================================================
# ATAQUE 4: ICMP Flood (Ping flood)      ~T=160s, 30s de duração
# ==========================================================================
log "Ataque 4: ICMP Flood → $AMF_IP"
TS=$(elapsed)
docker exec oai-attacker timeout 30 \
  hping3 -1 --flood "$AMF_IP" >/dev/null 2>&1 || true
TE=$(elapsed)
label "attack_icmp_flood" "$KALI_IP" "$AMF_IP" "$TS" "$TE"
log "Ataque 4 finalizado (${TS}s→${TE}s)."
sleep 10

# ==========================================================================
# ATAQUE 5 (opcional): CVE exploit      ~T=200s
# Descomente quando o script do exploit estiver pronto
# ==========================================================================
# log "Ataque 5: Exploit CVE-2025-XXXXX → $AMF_IP"
# TS=$(elapsed)
# python3 scripts/exploits/cve_exploit.py --target "$AMF_IP" || true
# TE=$(elapsed)
# label "attack_cve_exploit" "$KALI_IP" "$AMF_IP" "$TS" "$TE"
# log "Ataque 5 finalizado (${TS}s→${TE}s)."

# Aguarda o restante dos 5 minutos para o benigno completar
REMAINING=$(( TOTAL_DURATION - $(elapsed) ))
if [[ "$REMAINING" -gt 0 ]]; then
  log "Aguardando mais ${REMAINING}s para completar os 5 minutos..."
  sleep "$REMAINING"
fi

# --- Finalização ----------------------------------------------------------
log "Encerrando captura..."
cleanup
trap - EXIT

# Ajusta permissões
sudo_run chown "$USER":"$(id -gn)" "$PCAP_RAW" || true

# Filtra protocolos do Core 5G (SBA, NGAP, PFCP, GTP-C)
log "Gerando PCAP filtrado (http2, ngap, pfcp, gtp)..."
tshark -r "$PCAP_RAW" \
  -Y "http2 or ngap or pfcp or gtp" \
  -w "$PCAP_FILTERED"

sudo_run chown "$USER":"$(id -gn)" "$PCAP_FILTERED" || true

echo ""
echo "=== Concluído ==="
echo "PCAP bruto:    $PCAP_RAW"
echo "PCAP filtrado: $PCAP_FILTERED"
echo "Rótulos CSV:   $LABELS_CSV"
echo ""
cat "$LABELS_CSV"