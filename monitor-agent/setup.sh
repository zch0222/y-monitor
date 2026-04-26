#!/usr/bin/env bash
# One-time setup for a monitored agent server.
# Run this once after copying the monitor-agent directory to the server.
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v tailscale &>/dev/null; then
  echo "ERROR: tailscale is not installed or not in PATH."
  exit 1
fi

TS_IP=$(tailscale ip -4 | head -n1)
if [[ -z "${TS_IP}" ]]; then
  echo "ERROR: Could not determine Tailscale IPv4. Is tailscale running?"
  exit 1
fi

echo "==> Tailscale IP: ${TS_IP}"
echo "TS_IP=${TS_IP}" > .env
echo "==> Written to .env"

echo "==> Starting agent containers..."
docker compose up -d

echo ""
echo "==> Verifying listeners (expect ${TS_IP}:9100/9115/8080)..."
sleep 3
ss -lntp | grep -E '9100|9115|8080' || true

echo ""
echo "==> Agent setup complete."
echo "    Add this node to the central monitoring servers.txt:"
echo "    ${TS_IP}    <node_name>    <region>    yes"
