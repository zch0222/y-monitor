#!/usr/bin/env bash
# Smoke test for the central monitoring server.
# Verifies Prometheus, Grafana, and Alertmanager are healthy,
# configs are valid, and at least one target is being scraped.
set -euo pipefail

cd "$(dirname "$0")"

# ── Helpers ───────────────────────────────────────────────────────────────────

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

# ── Load .env ─────────────────────────────────────────────────────────────────

if [[ ! -f .env ]]; then
  echo "ERROR: .env not found. Run setup.sh first."
  exit 1
fi
set -a; source .env; set +a

echo ""
echo "========================================"
echo "  monitoring smoke test"
echo "========================================"

# ── 1. Container status ───────────────────────────────────────────────────────

section "Container status"

for name in prometheus grafana alertmanager; do
  state=$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null || echo "missing")
  if [[ "$state" == "running" ]]; then
    pass "$name is running"
  else
    fail "$name" "state=$state"
  fi
done

# ── 2. HTTP health endpoints ──────────────────────────────────────────────────

section "HTTP health endpoints"

http_ok "http://127.0.0.1:9090/-/healthy"   "Prometheus /-/healthy"
http_ok "http://127.0.0.1:9093/-/healthy"   "Alertmanager /-/healthy"
http_ok "http://127.0.0.1:3000/api/health"  "Grafana /api/health"

# ── 3. Config validation ──────────────────────────────────────────────────────

section "Config validation"

if docker exec prometheus promtool check config /etc/prometheus/prometheus.yml \
     > /dev/null 2>&1; then
  pass "prometheus.yml syntax valid"
else
  fail "prometheus.yml syntax valid" "run: docker exec prometheus promtool check config /etc/prometheus/prometheus.yml"
fi

if docker exec prometheus promtool check rules /etc/prometheus/rules/alerts.yml \
     > /dev/null 2>&1; then
  pass "alerts.yml syntax valid"
else
  fail "alerts.yml syntax valid" "run: docker exec prometheus promtool check rules /etc/prometheus/rules/alerts.yml"
fi

# ── 4. Target files ───────────────────────────────────────────────────────────

section "Prometheus target files"

for f in nodes.yml cadvisor.yml blackbox-exporters.yml blackbox_http.yml blackbox_icmp.yml blackbox_tcp.yml; do
  path="prometheus/targets/${f}"
  if [[ -f "$path" && -s "$path" ]]; then
    pass "$f exists and is non-empty"
  elif [[ -f "$path" ]]; then
    fail "$f is empty" "run ./gen-targets.sh after editing servers.txt"
  else
    fail "$f not found" "run ./gen-targets.sh"
  fi
done

# ── 5. Prometheus scrape targets ──────────────────────────────────────────────

section "Prometheus scrape targets"

targets_json=$(curl -s --connect-timeout 5 \
  'http://127.0.0.1:9090/api/v1/targets?state=active' 2>/dev/null || echo "{}")

up_count=$(echo "$targets_json" | grep -o '"health":"up"' | wc -l | tr -d ' ')
down_count=$(echo "$targets_json" | grep -o '"health":"down"' | wc -l | tr -d ' ')
total=$((up_count + down_count))

if [[ $total -eq 0 ]]; then
  fail "Prometheus has active targets" "no targets found — Prometheus may still be starting"
elif [[ $up_count -gt 0 ]]; then
  pass "Prometheus targets: ${up_count} UP, ${down_count} DOWN (total ${total})"
else
  fail "At least one target is UP" "all ${total} targets are DOWN"
fi

# Warn (but don't fail) if there are DOWN targets
if [[ $down_count -gt 0 && $up_count -gt 0 ]]; then
  echo "  [WARN] ${down_count} target(s) are DOWN — check http://127.0.0.1:9090/targets"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "──────────────────────────────────────────"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "──────────────────────────────────────────"

[[ $FAIL -eq 0 ]]
