#!/usr/bin/env bash
# Smoke test for monitor-agent.
# Verifies all three exporters are running and returning valid metrics.
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
echo "  monitor-agent smoke test"
echo "  TS_IP: ${TS_IP}"
echo "========================================"

# ── 1. Container status ───────────────────────────────────────────────────────

section "Container status"

for name in node_exporter blackbox_exporter cadvisor; do
  state=$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null || echo "missing")
  if [[ "$state" == "running" ]]; then
    pass "$name is running"
  else
    fail "$name" "state=$state"
  fi
done

# ── 2. HTTP endpoints ─────────────────────────────────────────────────────────

section "HTTP endpoints"

http_ok() {
  local url="$1" label="$2"
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "$url" 2>/dev/null || echo "000")
  if [[ "$code" == "200" ]]; then
    pass "$label (HTTP $code)"
  else
    fail "$label" "HTTP $code — is the container running and listening on ${TS_IP}?"
  fi
}

http_ok "http://${TS_IP}:9100/metrics"  "node_exporter /metrics"
http_ok "http://${TS_IP}:9115/metrics"  "blackbox_exporter /metrics"
http_ok "http://${TS_IP}:8080/metrics"  "cadvisor /metrics"

# ── 3. Blackbox probe ─────────────────────────────────────────────────────────

section "Blackbox probe"

probe_result=$(curl -s --connect-timeout 10 \
  "http://${TS_IP}:9115/probe?target=https://www.baidu.com&module=http_2xx" \
  2>/dev/null | grep '^probe_success' | awk '{print $2}')

if [[ "$probe_result" == "1" ]]; then
  pass "blackbox HTTP probe → https://www.baidu.com (probe_success 1)"
else
  fail "blackbox HTTP probe → https://www.baidu.com" "probe_success=${probe_result:-no response}"
fi

probe_icmp=$(curl -s --connect-timeout 10 \
  "http://${TS_IP}:9115/probe?target=223.5.5.5&module=icmp_ping" \
  2>/dev/null | grep '^probe_success' | awk '{print $2}')

if [[ "$probe_icmp" == "1" ]]; then
  pass "blackbox ICMP probe → 223.5.5.5 (probe_success 1)"
else
  fail "blackbox ICMP probe → 223.5.5.5" "probe_success=${probe_icmp:-no response} (check cap_add: NET_RAW)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "──────────────────────────────────────────"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "──────────────────────────────────────────"

[[ $FAIL -eq 0 ]]
