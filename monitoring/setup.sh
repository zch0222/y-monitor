#!/usr/bin/env bash
# One-time setup for the central monitoring server.
# Run this once after cloning the repo.
set -euo pipefail

cd "$(dirname "$0")"

# ── 1. Ensure .env exists ─────────────────────────────────────────────────────
if [[ ! -f .env ]]; then
  echo "ERROR: .env not found."
  echo "       Copy .env.example to .env and fill in your values first:"
  echo "       cp .env.example .env && vim .env"
  exit 1
fi

# Load .env for use in this script
set -a
# shellcheck disable=SC1091
source .env
set +a

# ── 2. Create runtime data directories ───────────────────────────────────────
echo "==> Creating runtime data directories..."
mkdir -p data/prometheus data/alertmanager grafana/data

echo "==> Fixing Grafana data directory permissions (UID 472)..."
sudo chown -R 472:472 grafana/data
sudo chmod -R u+rwX grafana/data

# ── 3. Generate nginx config from template ────────────────────────────────────
echo "==> Generating nginx/monitor.conf from template..."
if [[ -z "${DOMAIN:-}" || -z "${CERT_DIR:-}" ]]; then
  echo "ERROR: DOMAIN and CERT_DIR must be set in .env"
  exit 1
fi
# Only substitute ${DOMAIN} and ${CERT_DIR}; leave nginx variables ($host etc) untouched.
envsubst '${DOMAIN} ${CERT_DIR}' < nginx/monitor.conf.template > nginx/monitor.conf
echo "       Written to nginx/monitor.conf"

# ── 4. Generate Prometheus target files ──────────────────────────────────────
echo "==> Generating Prometheus target files..."
chmod +x gen-targets.sh
./gen-targets.sh

echo ""
echo "==> Done. Next steps:"
echo "    1. Edit servers.txt and add your Tailscale nodes"
echo "    2. Edit probes/ files to configure probe targets"
echo "    3. Copy nginx/monitor.conf to /etc/nginx/conf.d/monitor.conf"
echo "       and add the map block to /etc/nginx/nginx.conf (see template comments)"
echo "    4. Run: nginx -t && systemctl reload nginx"
echo "    5. Run: docker compose up -d"
echo "    6. Run: docker exec prometheus promtool check config /etc/prometheus/prometheus.yml"
