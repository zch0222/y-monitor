#!/usr/bin/env bash
# Security test for a standalone Loki log server.
set -euo pipefail

cd "$(dirname "$0")"

PASS=0
FAIL=0

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1${2:+ — $2}"; FAIL=$((FAIL + 1)); }
section() { echo ""; echo "── $1 ──────────────────────────────────────"; }

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
echo "  loki security test"
echo "  LOKI_TS_IP: ${LOKI_TS_IP}"
echo "========================================"

section "Port binding"

listeners=$(ss -lntp 2>/dev/null)

if echo "$listeners" | grep -q "0\.0\.0\.0:3100"; then
  fail "Loki port 3100 not exposed on 0.0.0.0" "bind Loki to LOKI_TS_IP"
else
  pass "Loki port 3100 not exposed on 0.0.0.0"
fi

if echo "$listeners" | grep -q "${LOKI_TS_IP}:3100"; then
  pass "Loki listening on Tailscale IP"
else
  fail "Loki listening on Tailscale IP" "${LOKI_TS_IP}:3100 not found"
fi

section "Docker Compose configuration"

if grep -q '^\s*ports:' docker-compose.yml; then
  fail "docker-compose.yml has no 'ports:' mapping" "found 'ports:' — Docker bypasses UFW for mapped ports"
else
  pass "docker-compose.yml has no 'ports:' mapping"
fi

if grep -q 'network_mode: host' docker-compose.yml; then
  pass "Loki uses network_mode: host"
else
  fail "Loki uses network_mode: host" "bind directly to Tailscale IP"
fi

if grep -q 'http_listen_address: ${LOKI_TS_IP}' config/loki.yml; then
  pass "Loki config binds to LOKI_TS_IP"
else
  fail "Loki config binds to LOKI_TS_IP" "avoid binding Loki to public interfaces"
fi

if grep -q 'auth_enabled: false' config/loki.yml; then
  pass "Loki auth is disabled only behind Tailscale boundary"
else
  fail "Loki auth setting is explicit" "review auth_enabled in config/loki.yml"
fi

section "Sensitive files"

if git rev-parse --git-dir &>/dev/null; then
  if git ls-files --error-unmatch .env &>/dev/null 2>&1; then
    fail ".env is not tracked by git" ".env is committed — remove it from git history"
  else
    pass ".env is not tracked by git"
  fi
else
  echo "  [SKIP] Not a git repository"
fi

echo ""
echo "──────────────────────────────────────────"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "──────────────────────────────────────────"

[[ $FAIL -eq 0 ]]
