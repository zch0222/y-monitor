#!/usr/bin/env bash
# Security test for monitor-agent.
# Verifies that exporter ports are only reachable via Tailscale IP,
# not exposed on 0.0.0.0 or 127.0.0.1.
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

if [[ -z "${TS_IP:-}" ]]; then
  echo "ERROR: TS_IP is not set in .env"
  exit 1
fi

echo ""
echo "========================================"
echo "  monitor-agent security test"
echo "  TS_IP: ${TS_IP}"
echo "========================================"

# ── 1. Port binding ───────────────────────────────────────────────────────────

section "Port binding"

listeners=$(ss -lntp 2>/dev/null)

for port in 9100 9115 8080; do
  # Must NOT be bound to 0.0.0.0
  if echo "$listeners" | grep -q "0\.0\.0\.0:${port}"; then
    fail "Port $port NOT exposed on 0.0.0.0" "found 0.0.0.0:${port} — exporter may be reachable from public internet"
  else
    pass "Port $port not exposed on 0.0.0.0"
  fi

  # Must NOT be bound to 127.0.0.1 (localhost-only means Prometheus can't reach it)
  if echo "$listeners" | grep -q "127\.0\.0\.1:${port}"; then
    fail "Port $port not bound to loopback only" "found 127.0.0.1:${port} — Prometheus cannot scrape across machines"
  else
    pass "Port $port not bound to loopback only"
  fi

  # Must be bound to TS_IP
  if echo "$listeners" | grep -q "${TS_IP}:${port}"; then
    pass "Port $port listening on Tailscale IP (${TS_IP}:${port})"
  else
    fail "Port $port listening on Tailscale IP" "${TS_IP}:${port} not found — check .env and restart containers"
  fi
done

# ── 2. Docker Compose config ──────────────────────────────────────────────────

section "Docker Compose configuration"

# No ports: mapping (would bypass UFW)
if grep -q '^\s*ports:' docker-compose.yml; then
  fail "docker-compose.yml has no 'ports:' mapping" "found 'ports:' — remove it; use network_mode: host instead"
else
  pass "docker-compose.yml has no 'ports:' mapping"
fi

# All services use network_mode: host
host_count=$(grep -c 'network_mode: host' docker-compose.yml || true)
service_count=$(grep -c '^\s*[a-z_]*:$' docker-compose.yml || true)
if [[ "$host_count" -ge 3 ]]; then
  pass "All services use network_mode: host"
else
  fail "All services use network_mode: host" "found ${host_count}/3 services with network_mode: host"
fi

# ── 3. Sensitive files ────────────────────────────────────────────────────────

section "Sensitive files"

# .env must not be tracked by git
if git rev-parse --git-dir &>/dev/null; then
  if git ls-files --error-unmatch .env &>/dev/null 2>&1; then
    fail ".env is not tracked by git" ".env is committed — it contains TS_IP, remove it from git history"
  else
    pass ".env is not tracked by git"
  fi
else
  echo "  [SKIP] Not a git repository"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "──────────────────────────────────────────"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "──────────────────────────────────────────"

[[ $FAIL -eq 0 ]]
