#!/usr/bin/env bash
# One-time setup for a monitored agent server.
# Run this once after copying the monitor-agent directory to the server.
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

if ! command -v docker &>/dev/null; then
  echo "ERROR: docker is not installed or not in PATH."
  exit 1
fi

TS_IP=$(tailscale ip -4 | head -n1)
if [[ -z "${TS_IP}" ]]; then
  echo "ERROR: Could not determine Tailscale IPv4. Is tailscale running?"
  exit 1
fi

created_env=0

# Write .env (preserve existing custom values if .env already exists)
if [[ -f .env ]]; then
  set_env_value TS_IP "$TS_IP"
else
  cp .env.example .env
  created_env=1
  set_env_value TS_IP "$TS_IP"
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

if [[ -z "${ENVIRONMENT:-}" ]]; then
  ENVIRONMENT="prod"
  set_env_value ENVIRONMENT "$ENVIRONMENT"
fi

if [[ -z "${NODE_NAME:-}" || ( "$created_env" -eq 1 && "${NODE_NAME}" == "app-01" ) ]]; then
  NODE_NAME=$(hostname -s)
  set_env_value NODE_NAME "$NODE_NAME"
fi

if [[ -z "${LOKI_PUSH_URL:-}" || "${LOKI_PUSH_URL}" == *"100.x.x.x"* ]]; then
  ask LOKI_PUSH_URL "Loki push URL (e.g. http://100.x.y.z:3100/loki/api/v1/push)"
  set_env_value LOKI_PUSH_URL "$LOKI_PUSH_URL"
fi

mkdir -p data/promtail

if [[ ! -f promtail/config.yml ]]; then
  echo "ERROR: promtail/config.yml not found."
  exit 1
fi

if [[ ! -S /var/run/docker.sock ]]; then
  echo "ERROR: /var/run/docker.sock not found. Is Docker running?"
  exit 1
fi

log_driver=$(docker info --format '{{.LoggingDriver}}' 2>/dev/null || echo "unknown")
if [[ "$log_driver" == "json-file" || "$log_driver" == "journald" ]]; then
  echo "==> Docker logging driver: ${log_driver}"
else
  echo "WARN: Docker logging driver is '${log_driver}'. Promtail docker_sd_configs expects json-file or journald."
fi

echo "==> Tailscale IP: ${TS_IP}"
echo "==> Written to .env"
echo ""
echo "    Current .env:"
cat .env
echo ""

echo "==> Starting agent containers..."
docker compose up -d

if [[ -n "${LOKI_PUSH_URL:-}" ]]; then
  loki_base="${LOKI_PUSH_URL%/loki/api/v1/push}"
  echo ""
  echo "==> Checking Loki endpoint: ${loki_base}/ready"
  if curl -fsS --connect-timeout 5 "${loki_base}/ready" >/dev/null 2>&1; then
    echo "    Loki is reachable."
  else
    echo "    WARN: Loki is not reachable from this host yet."
  fi
fi

echo ""
echo "==> Verifying listeners (expect ${TS_IP}:9100/9115/8080/9080)..."
sleep 3
ss -lntp | grep -E '9100|9115|8080|9080' || true

echo ""
echo "==> Agent setup complete."
echo "    Add this node to the central monitoring servers.txt:"
echo "    ${TS_IP}    <node_name>    <region>    yes"
echo ""
echo "    Next steps:"
echo "    1. Ensure Docker daemon uses json-file rotation."
echo "    2. Add label logging=promtail to business containers."
echo "    3. Restart target business containers after daemon.json changes."
echo "    4. Verify in Grafana Explore: {job=\"docker\", instance=\"${NODE_NAME}\"}"
