#!/usr/bin/env bash
set -euo pipefail

missing=0

for cmd in docker tshark; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[erro] comando ausente: $cmd"
    missing=1
  fi
done

if [[ "$missing" -ne 0 ]]; then
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "[erro] Docker daemon indisponível"
  exit 1
fi

host_arch="$(uname -m)"
echo "Host architecture: $host_arch"

if [[ "$host_arch" != "x86_64" ]]; then
  echo "[aviso] Core 5G pode subir, mas a RAN tende a falhar neste host."
  echo "[aviso] Para fluxo completo, use Linux x86_64."
fi

echo "Preflight concluído."
