# Checklist rápido (execução em Linux x86_64)

Use este checklist para executar o fluxo completo do OAI em outra máquina.

## 1) Pré-requisitos (host remoto)

- [ ] Sistema: Linux x86_64
- [ ] Docker Engine instalado
- [ ] Docker Compose plugin instalado
- [ ] `tshark` instalado
- [ ] `rsync` instalado
- [ ] SSH funcionando

## 2) Sincronizar projeto (a partir do host atual)

```bash
cd /Users/drt82247/Documents/Projetos/IME/CDR/oai/oai-workshops/cn
chmod +x scripts/remote_sync.sh
REMOTE_USER=<usuario_linux> REMOTE_HOST=<ip_ou_hostname> REMOTE_BASE=~/oai ./scripts/remote_sync.sh
```

## 3) Executar pipeline (no host remoto)

```bash
ssh <usuario_linux>@<ip_ou_hostname>
cd ~/oai/oai-workshops/cn
chmod +x scripts/*.sh
./scripts/00_preflight.sh
./scripts/run_pipeline.sh
```

## 4) Saídas esperadas

- [ ] `results/cve5g_internal_benign.pcap`
- [ ] `results/cve5g_internal_benign_filtrado.pcap`

Validação rápida:

```bash
ls -lh results/*.pcap
```

## 5) Baixar resultados para o host atual

```bash
mkdir -p /Users/drt82247/Documents/Projetos/IME/CDR/oai/oai-workshops/cn/results
rsync -avz <usuario_linux>@<ip_ou_hostname>:~/oai/oai-workshops/cn/results/*.pcap /Users/drt82247/Documents/Projetos/IME/CDR/oai/oai-workshops/cn/results/
```

## 6) Se der erro

- `tshark não encontrado` → instalar `tshark`
- `Cannot connect to the Docker daemon` → iniciar Docker / validar `docker info`
- `Illegal instruction` ou `exec format error` → host incompatível (não x86_64)
