#!/usr/bin/env bash
# Setup script for a standalone Loki log server.
set -euo pipefail

cd "$(dirname "$0")"

ask() {
  # ask <VAR_NAME> <prompt> [default]
  local var="$1" prompt="$2" default="${3:-}"
  local value=""
  if [[ -n "$default" ]]; then
    read -rp "${prompt} [${default}]: " value
    value="${value:-$default}"
  else
    while [[ -z "$value" ]]; do
      read -rp "${prompt}: " value
    done
  fi
  printf -v "$var" '%s' "$value"
}

set_env_value() {
  # set_env_value <KEY> <VALUE>
  local key="$1" value="$2"
  if [[ -f .env ]] && grep -q "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${value}|" .env
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
}

if ! command -v tailscale &>/dev/null; then
  echo "ERROR: tailscale is not installed or not in PATH."
  exit 1
fi

LOKI_TS_IP=$(tailscale ip -4 | head -n1)
if [[ -z "${LOKI_TS_IP}" ]]; then
  echo "ERROR: Could not determine Tailscale IPv4. Is tailscale running?"
  exit 1
fi

if [[ -f .env ]]; then
  set_env_value LOKI_TS_IP "$LOKI_TS_IP"
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a

  if [[ -z "${LOKI_RETENTION:-}" ]]; then
    LOKI_RETENTION="336h"
    set_env_value LOKI_RETENTION "$LOKI_RETENTION"
  fi
else
  cp .env.example .env
  set_env_value LOKI_TS_IP "$LOKI_TS_IP"
  ask TZ "Timezone for Loki container" "Asia/Shanghai"
  ask LOKI_RETENTION "Loki retention" "336h"
  set_env_value TZ "$TZ"
  set_env_value LOKI_RETENTION "$LOKI_RETENTION"
fi

mkdir -p data

echo "==> Fixing Loki data directory permissions (UID 10001)..."
sudo chown -R 10001:10001 data
sudo chmod -R u+rwX data

if [[ ! -f config/loki.yml ]]; then
  echo "ERROR: config/loki.yml not found."
  exit 1
fi

echo "==> Loki Tailscale IP: ${LOKI_TS_IP}"
echo "==> Written to .env"
echo ""
echo "    Current .env:"
cat .env
echo ""
echo "==> Setup complete. Next steps:"
echo "    1. Run: docker compose up -d"
echo "    2. Verify: curl -fsS http://${LOKI_TS_IP}:3100/ready"
echo "    3. Configure monitor-agent LOKI_PUSH_URL:"
echo "       http://${LOKI_TS_IP}:3100/loki/api/v1/push"
echo "    4. Configure monitoring LOKI_URL:"
echo "       http://${LOKI_TS_IP}:3100"
