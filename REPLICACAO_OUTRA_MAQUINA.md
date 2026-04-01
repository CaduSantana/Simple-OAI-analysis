# Replicação em outra máquina (handoff completo)

Este documento consolida tudo que já foi feito neste workspace para facilitar a replicação em outra máquina.

## 1) Contexto e objetivo

- Objetivo: executar o fluxo do arquivo `Execução inicial.pdf` para OpenAirInterface, gerando:
  - `results/cve5g_internal_benign.pcap`
  - `results/cve5g_internal_benign_filtrado.pcap`
- Ambiente atual: macOS com Apple Silicon (ARM64).
- Limitação encontrada: os componentes RAN (`oai-gnb`, `oai-nr-ue1`) usam imagens `linux/amd64` e falham em ARM.

## 2) O que foi implementado

No diretório `oai-workshops/cn`:

- `scripts/00_preflight.sh`
  - valida `docker`, `tshark`, daemon Docker e arquitetura.
- `scripts/01_bootstrap.sh`
  - sobe `mysql`, Core 5G, aguarda estabilização e sobe RAN.
  - valida se `oai-gnb` e `oai-nr-ue1` ficaram `running`.
- `scripts/02_generate_benign.sh`
  - captura em `oaiworkshop` com `tshark`.
  - gera tráfego TCP/UDP com `iperf3`.
  - finaliza captura e ajusta permissões.
- `scripts/03_filter_pcap.sh`
  - filtra `http2 or ngap or pfcp`.
- `scripts/04_shutdown.sh`
  - derruba RAN e Core.
- `scripts/run_pipeline.sh`
  - executa a sequência completa.
- `scripts/remote_sync.sh`
  - sincroniza o projeto por `rsync` para host remoto.

## 3) Execução realizada até agora

### 3.1 No macOS local (ARM64)

- `./scripts/01_bootstrap.sh`
  - Core 5G subiu com sucesso.
  - RAN não permaneceu ativa.
- `./scripts/02_generate_benign.sh`
  - falhou por ausência de `tshark` local.

Erros observados nos logs:

- `Illegal instruction`
- `exec /tini: exec format error`

Conclusão: ambiente ARM não suporta execução completa da RAN com essas imagens.

### 3.2 Na VM `Bumbumtu`

- Acesso remoto por SSH via NAT (`127.0.0.1:2222`) foi configurado e validado.
- Projeto sincronizado por `rsync` para `~/oai/oai-workshops`.
- Pipeline remoto executado.
- Resultado: novamente falha da RAN por arquitetura ARM (`Ubuntu (ARM 64-bit)`).

## 4) Requisitos para sucesso (máquina de destino)

Use **Linux x86_64** com:

- Docker Engine
- Docker Compose plugin
- `tshark`
- `rsync`
- SSH

## 5) Passo a passo para replicar em máquina x86_64

### 5.1 Do host atual para o host remoto

No host atual:

```bash
cd /Users/drt82247/Documents/Projetos/IME/CDR/oai/oai-workshops/cn
chmod +x scripts/remote_sync.sh
REMOTE_USER=<usuario_linux> REMOTE_HOST=<ip_ou_hostname> REMOTE_BASE=~/oai ./scripts/remote_sync.sh
```

### 5.2 No host remoto x86_64

```bash
ssh <usuario_linux>@<ip_ou_hostname>
cd ~/oai/oai-workshops/cn
chmod +x scripts/*.sh
./scripts/00_preflight.sh
./scripts/run_pipeline.sh
```

### 5.3 Coletar os resultados

No host atual:

```bash
mkdir -p /Users/drt82247/Documents/Projetos/IME/CDR/oai/oai-workshops/cn/results
rsync -avz <usuario_linux>@<ip_ou_hostname>:~/oai/oai-workshops/cn/results/*.pcap /Users/drt82247/Documents/Projetos/IME/CDR/oai/oai-workshops/cn/results/
```

## 6) Verificações rápidas

No host remoto durante a execução:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

Após o pipeline, validar arquivos:

```bash
ls -lh results/*.pcap
```

## 7) Troubleshooting objetivo

- `tshark não encontrado`
  - instale `tshark` no host.
- `Cannot connect to the Docker daemon`
  - iniciar Docker e validar com `docker info`.
- `Illegal instruction` / `exec format error`
  - indica incompatibilidade de arquitetura (ARM executando imagem amd64).
  - mover execução para Linux x86_64.
