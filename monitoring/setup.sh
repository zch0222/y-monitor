#!/usr/bin/env bash
# One-time setup for the central monitoring server.
# Run this once after cloning the repo.
set -euo pipefail

cd "$(dirname "$0")"

echo "==> Creating runtime data directories..."
mkdir -p data/prometheus data/alertmanager grafana/data

echo "==> Fixing Grafana data directory permissions (UID 472)..."
sudo chown -R 472:472 grafana/data
sudo chmod -R u+rwX grafana/data

echo "==> Generating Prometheus target files..."
chmod +x gen-targets.sh
./gen-targets.sh

echo ""
echo "==> Done. Next steps:"
echo "    1. Edit servers.txt and add your Tailscale nodes"
echo "    2. Edit probes/ files to configure probe targets"
echo "    3. Edit docker-compose.yml: update GF_SERVER_ROOT_URL to your domain"
echo "    4. Edit nginx/monitor.conf: replace monitor.example.com with your domain"
echo "    5. Run: docker compose up -d"
echo "    6. Run: docker exec prometheus promtool check config /etc/prometheus/prometheus.yml"
