# Execução inicial (automação do PDF)

Este diretório implementa as instruções do arquivo **Execução inicial.pdf** em scripts executáveis.

Para um handoff completo (histórico da execução, limitações ARM e roteiro de replicação em outra máquina), consulte `REPLICACAO_OUTRA_MAQUINA.md`.
Para uma versão curta de compartilhamento, consulte `CHECKLIST_X86_64_RAPIDO.md`.

## Pré-requisitos

- Docker + Docker Compose plugin
- `tshark` instalado no host
- Permissão `sudo` para captura na interface `oaiworkshop`
- **Para RAN (`oai-gnb` e `oai-nr-ue1`) use Linux x86_64**

## Scripts criados

- `scripts/01_bootstrap.sh`  
  Sobe `mysql`, Core 5G e RAN (`oai-gnb` + `oai-nr-ue1`).

- `scripts/02_generate_benign.sh`  
  Captura tráfego interno (`results/cve5g_internal_benign.pcap`) e gera:
  - TCP download (`iperf3 -R -t 60`)
  - UDP streaming (`iperf3 -u -b 2M -t 60`)

- `scripts/03_filter_pcap.sh`  
  Filtra protocolos `http2 or ngap or pfcp` para:
  `results/cve5g_internal_benign_filtrado.pcap`.

- `scripts/04_shutdown.sh`  
  Derruba RAN e Core 5G.

- `scripts/run_pipeline.sh`  
  Executa todo o fluxo acima em sequência.

## Execução

No diretório `cn`:

```bash
./scripts/run_pipeline.sh
```

Ou passo a passo:

```bash
./scripts/01_bootstrap.sh
./scripts/02_generate_benign.sh
./scripts/03_filter_pcap.sh
./scripts/04_shutdown.sh
```

## Observações

- Se o IP da interface UE for diferente de `10.0.0.2`, execute com:

```bash
UE_BIND_IP=<ip_da_ue> ./scripts/02_generate_benign.sh
```

## Migração para Linux x86_64 (RAN funcional)

No host Linux x86_64, instale Docker, Docker Compose e tshark. Depois, no host atual, envie o projeto:

```bash
export REMOTE_USER=<usuario_linux>
export REMOTE_HOST=<ip_ou_hostname_linux>
export REMOTE_BASE=~/oai

rsync -avz --delete \
  --exclude '.git' \
  --exclude 'results/*.pcap' \
  /Users/drt82247/Documents/Projetos/IME/CDR/oai/oai-workshops/ \
  ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_BASE}/oai-workshops/
```

Executar remotamente:

```bash
ssh ${REMOTE_USER}@${REMOTE_HOST} "cd ${REMOTE_BASE}/oai-workshops/cn && chmod +x scripts/*.sh && ./scripts/run_pipeline.sh"
```
