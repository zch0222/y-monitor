#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-$(cd "$(dirname "$0")" && pwd)}"
TARGET_DIR="${ROOT}/prometheus/targets"
SERVER_FILE="${ROOT}/servers.txt"
PROBE_DIR="${ROOT}/probes"

NODE_FILE="${TARGET_DIR}/nodes.yml"
CADVISOR_FILE="${TARGET_DIR}/cadvisor.yml"
BLACKBOX_EXPORTERS_FILE="${TARGET_DIR}/blackbox-exporters.yml"
HTTP_FILE="${TARGET_DIR}/blackbox_http.yml"
ICMP_FILE="${TARGET_DIR}/blackbox_icmp.yml"
TCP_FILE="${TARGET_DIR}/blackbox_tcp.yml"

mkdir -p "${TARGET_DIR}"

: > "${NODE_FILE}"
: > "${CADVISOR_FILE}"
: > "${BLACKBOX_EXPORTERS_FILE}"
: > "${HTTP_FILE}"
: > "${ICMP_FILE}"
: > "${TCP_FILE}"

read_data_lines() {
  local file="$1"
  if [[ -f "$file" ]]; then
    grep -Ev '^[[:space:]]*(#|$)' "$file"
  fi
}

gen_node_targets() {
  while read -r ip node region cadvisor_enabled rest; do
    cat >> "${NODE_FILE}" <<EOF
- targets:
    - "${ip}:9100"
  labels:
    node: "${node}"
    region: "${region}"
    network: "tailscale"

EOF

    cat >> "${BLACKBOX_EXPORTERS_FILE}" <<EOF
- targets:
    - "${ip}:9115"
  labels:
    node: "${node}"
    region: "${region}"
    network: "tailscale"
    role: "blackbox_exporter"

EOF

    if [[ "${cadvisor_enabled}" == "yes" || "${cadvisor_enabled}" == "true" || "${cadvisor_enabled}" == "1" ]]; then
      cat >> "${CADVISOR_FILE}" <<EOF
- targets:
    - "${ip}:8080"
  labels:
    node: "${node}"
    region: "${region}"
    network: "tailscale"
    role: "docker"

EOF
    fi
  done < <(read_data_lines "${SERVER_FILE}")
}

gen_blackbox_http_targets() {
  while read -r ip node region cadvisor_enabled rest; do
    while read -r target direction rest2; do
      cat >> "${HTTP_FILE}" <<EOF
- targets:
    - "${target}"
  labels:
    probe_node: "${node}"
    probe_region: "${region}"
    direction: "${direction}"
    probe_type: "http"
    network: "tailscale"
    blackbox_address: "${ip}:9115"

EOF
    done < <(read_data_lines "${PROBE_DIR}/http_targets.txt")
  done < <(read_data_lines "${SERVER_FILE}")
}

gen_blackbox_icmp_targets() {
  while read -r ip node region cadvisor_enabled rest; do
    while read -r target direction rest2; do
      cat >> "${ICMP_FILE}" <<EOF
- targets:
    - "${target}"
  labels:
    probe_node: "${node}"
    probe_region: "${region}"
    direction: "${direction}"
    probe_type: "icmp"
    network: "tailscale"
    blackbox_address: "${ip}:9115"

EOF
    done < <(read_data_lines "${PROBE_DIR}/icmp_targets.txt")
  done < <(read_data_lines "${SERVER_FILE}")
}

gen_blackbox_tcp_targets() {
  while read -r ip node region cadvisor_enabled rest; do
    while read -r target direction rest2; do
      cat >> "${TCP_FILE}" <<EOF
- targets:
    - "${target}"
  labels:
    probe_node: "${node}"
    probe_region: "${region}"
    direction: "${direction}"
    probe_type: "tcp"
    network: "tailscale"
    blackbox_address: "${ip}:9115"

EOF
    done < <(read_data_lines "${PROBE_DIR}/tcp_targets.txt")
  done < <(read_data_lines "${SERVER_FILE}")
}

gen_node_targets
gen_blackbox_http_targets
gen_blackbox_icmp_targets
gen_blackbox_tcp_targets

echo "Generated target files:"
ls -lh "${TARGET_DIR}"
