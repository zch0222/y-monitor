#!/usr/bin/env bash
# Smoke test for a standalone Loki log server.
set -euo pipefail

cd "$(dirname "$0")"

PASS=0
FAIL=0

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1${2:+ — $2}"; FAIL=$((FAIL + 1)); }
section() { echo ""; echo "── $1 ──────────────────────────────────────"; }

http_ok() {
  local url="$1" label="$2" expected="${3:-200}"
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "$url" 2>/dev/null || echo "000")
  if [[ "$code" == "$expected" ]]; then
    pass "$label (HTTP $code)"
  else
    fail "$label" "HTTP $code (expected $expected)"
  fi
}

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found. Run setup.sh first."
  exit 1
fi
set -a; source .env; set +a

if [[ -z "${LOKI_TS_IP:-}" ]]; then
  echo "ERROR: LOKI_TS_IP is not set in .env"
  exit 1
fi

echo ""
echo "========================================"
echo "  loki smoke test"
echo "  LOKI_TS_IP: ${LOKI_TS_IP}"
echo "========================================"

section "Container status"

state=$(docker inspect --format='{{.State.Status}}' loki 2>/dev/null || echo "missing")
if [[ "$state" == "running" ]]; then
  pass "loki is running"
else
  fail "loki" "state=$state"
fi

section "HTTP endpoints"

http_ok "http://${LOKI_TS_IP}:3100/ready" "Loki /ready"
http_ok "http://${LOKI_TS_IP}:3100/loki/api/v1/labels" "Loki labels API"

section "Recent logs"

if docker compose logs --tail=100 loki 2>/dev/null | grep -Eiq 'error|panic|invalid|failed'; then
  fail "Loki recent logs have no obvious errors" "check: docker compose logs --tail=100 loki"
else
  pass "Loki recent logs have no obvious errors"
fi

echo ""
echo "──────────────────────────────────────────"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "──────────────────────────────────────────"

[[ $FAIL -eq 0 ]]
