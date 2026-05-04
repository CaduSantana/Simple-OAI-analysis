# Migração para Linux x86_64

Este guia prepara a execução completa (Core + RAN + tráfego benigno + filtragem) em ambiente compatível.

## 1) Requisitos no host remoto

- Linux x86_64
- Docker Engine + Docker Compose plugin
- `tshark`
- Acesso SSH

## 2) Enviar o projeto

No host local:

```bash
cd /Users/drt82247/Documents/Projetos/IME/CDR/oai/oai-workshops/cn
chmod +x scripts/remote_sync.sh
REMOTE_USER=<usuario_linux> REMOTE_HOST=<ip_ou_hostname> REMOTE_BASE=~/oai ./scripts/remote_sync.sh
```

## 3) Executar no host remoto

```bash
ssh <usuario_linux>@<ip_ou_hostname>
cd ~/oai/oai-workshops/cn
chmod +x scripts/*.sh
./scripts/00_preflight.sh
./scripts/run_pipeline.sh
```

## 4) Coletar resultados

Arquivos esperados:

- `results/cve5g_internal_benign.pcap`
- `results/cve5g_internal_benign_filtrado.pcap`

Para baixar de volta:

```bash
rsync -avz <usuario_linux>@<ip_ou_hostname>:~/oai/oai-workshops/cn/results/*.pcap ./results/
```
