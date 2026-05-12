#!/usr/bin/env bash
set -euo pipefail

missing=0

for cmd in docker tshark; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[error] missing command: $cmd"
    missing=1
  fi
done

if [[ "$missing" -ne 0 ]]; then
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "[error] Docker daemon unavailable"
  exit 1
fi

host_arch="$(uname -m)"
echo "Host architecture: $host_arch"

if [[ "$host_arch" != "x86_64" ]]; then
  echo "[warning] The 5G Core may start, but the RAN is likely to fail on this host."
  echo "[warning] For the complete workflow, use Linux x86_64."
fi

echo "Preflight completed."