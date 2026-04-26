#!/usr/bin/env bash
# Security test for the central monitoring server.
# Verifies that Prometheus, Grafana, and Alertmanager are only reachable
# via localhost, not exposed on public interfaces.
set -euo pipefail

cd "$(dirname "$0")"

# ── Helpers ───────────────────────────────────────────────────────────────────

PASS=0
FAIL=0

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1${2:+ — $2}"; FAIL=$((FAIL + 1)); }

section() { echo ""; echo "── $1 ──────────────────────────────────────"; }

# ── Load .env ─────────────────────────────────────────────────────────────────

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found. Run setup.sh first."
  exit 1
fi
set -a; source .env; set +a

echo ""
echo "========================================"
echo "  monitoring security test"
echo "========================================"

# ── 1. Port binding ───────────────────────────────────────────────────────────

section "Port binding"

listeners=$(ss -lntp 2>/dev/null)

for port in 9090 9093 3000; do
  # Must NOT be bound to 0.0.0.0
  if echo "$listeners" | grep -q "0\.0\.0\.0:${port}"; then
    fail "Port $port not exposed on 0.0.0.0" "found 0.0.0.0:${port} — service is publicly reachable"
  else
    pass "Port $port not exposed on 0.0.0.0"
  fi

  # Must be bound to 127.0.0.1
  if echo "$listeners" | grep -q "127\.0\.0\.1:${port}"; then
    pass "Port $port listening on 127.0.0.1 only"
  else
    fail "Port $port listening on 127.0.0.1" "${port} not found on loopback — service may not be running"
  fi
done

# Port 9094 (Alertmanager cluster gossip) must NOT be listening
if echo "$listeners" | grep -q ":9094"; then
  fail "Alertmanager cluster port 9094 is not listening" \
    "9094 is open — add '--cluster.listen-address=' to alertmanager command"
else
  pass "Alertmanager cluster port 9094 is not listening"
fi

# ── 2. Docker Compose configuration ───────────────────────────────────────────

section "Docker Compose configuration"

# No ports: mapping (would bypass UFW/iptables)
if grep -q '^\s*ports:' docker-compose.yml; then
  fail "docker-compose.yml has no 'ports:' mapping" \
    "found 'ports:' — Docker bypasses UFW for mapped ports"
else
  pass "docker-compose.yml has no 'ports:' mapping"
fi

# Prometheus must listen on 127.0.0.1
if grep -q 'web.listen-address=127.0.0.1:9090' docker-compose.yml; then
  pass "Prometheus --web.listen-address=127.0.0.1:9090"
else
  fail "Prometheus --web.listen-address=127.0.0.1:9090" "check docker-compose.yml"
fi

# Alertmanager must listen on 127.0.0.1
if grep -q 'web.listen-address=127.0.0.1:9093' docker-compose.yml; then
  pass "Alertmanager --web.listen-address=127.0.0.1:9093"
else
  fail "Alertmanager --web.listen-address=127.0.0.1:9093" "check docker-compose.yml"
fi

# Alertmanager cluster must be disabled
if grep -q 'cluster.listen-address=' docker-compose.yml; then
  pass "Alertmanager --cluster.listen-address= (cluster disabled)"
else
  fail "Alertmanager --cluster.listen-address= (cluster disabled)" \
    "missing flag — port 9094 may be exposed"
fi

# ── 3. Grafana security config ────────────────────────────────────────────────

section "Grafana security config"

if grep -q 'GF_USERS_ALLOW_SIGN_UP=false' docker-compose.yml; then
  pass "GF_USERS_ALLOW_SIGN_UP=false"
else
  fail "GF_USERS_ALLOW_SIGN_UP=false" "public registration may be enabled"
fi

if grep -q 'GF_SECURITY_COOKIE_SECURE=true' docker-compose.yml; then
  pass "GF_SECURITY_COOKIE_SECURE=true"
else
  fail "GF_SECURITY_COOKIE_SECURE=true" "cookies not marked Secure — risky over HTTPS proxy"
fi

# ── 4. Sensitive files ────────────────────────────────────────────────────────

section "Sensitive files"

# .env must not be tracked by git
if git rev-parse --git-dir &>/dev/null; then
  if git ls-files --error-unmatch .env &>/dev/null 2>&1; then
    fail ".env is not tracked by git" ".env is committed — contains passwords, remove from git history"
  else
    pass ".env is not tracked by git"
  fi
else
  echo "  [SKIP] Not a git repository"
fi

# GF_ADMIN_PASSWORD must not be the default placeholder
default_pass="ChangeMe_123456"
if [[ "${GF_ADMIN_PASSWORD:-}" == "$default_pass" ]]; then
  fail "Grafana admin password is not the default" \
    "GF_ADMIN_PASSWORD is still '${default_pass}' — change it in .env"
else
  pass "Grafana admin password is not the default"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "──────────────────────────────────────────"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "──────────────────────────────────────────"

[[ $FAIL -eq 0 ]]
