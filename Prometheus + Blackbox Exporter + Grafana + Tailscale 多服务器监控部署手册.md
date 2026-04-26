# Prometheus + Blackbox Exporter + Grafana + Tailscale 多服务器监控部署手册

## 1. 方案目标

本方案用于监控多台服务器的：

- 主机指标：CPU、内存、磁盘、网络、负载
- Docker 容器指标：容器 CPU、内存、网络等
- 网络连通性：HTTP、TCP、ICMP 探测
- 国内 / 国际连接质量
- 服务可用性
- SSL 证书有效期
- 告警规则

整体思路是：

```text
中心监控机：
Prometheus + Grafana + Alertmanager

每台被监控服务器：
node_exporter + blackbox_exporter + cAdvisor

网络：
全部通过 Tailscale 内网采集，不暴露监控端口到公网
```

------

## 2. 最终架构

```text
                         Tailscale 内网
                             │
┌────────────────────────────┴────────────────────────────┐
│                      中心监控机                           │
│                                                          │
│  Prometheus     127.0.0.1:9090                            │
│  Grafana        127.0.0.1:3000    ← Nginx HTTPS 反代       │
│  Alertmanager   127.0.0.1:9093                            │
│                                                          │
│  servers.txt                                             │
│  gen-targets.sh                                          │
│  prometheus/targets/*.yml                                │
└───────────────┬───────────────────────┬─────────────────┘
                │                       │
                │ Tailscale             │ Tailscale
                │                       │
       100.x.x.11:9100         100.x.x.12:9100
       100.x.x.11:9115         100.x.x.12:9115
       100.x.x.11:8080         100.x.x.12:8080
                │                       │
        ┌───────▼────────┐      ┌───────▼────────┐
        │ 业务服务器 A    │      │ 业务服务器 B    │
        │ node_exporter  │      │ node_exporter  │
        │ blackbox       │      │ blackbox       │
        │ cAdvisor       │      │ cAdvisor       │
        └────────────────┘      └────────────────┘
```

------

## 3. 核心安全原则

本方案重点避免 Docker 端口映射绕过 UFW 的问题。

原则如下：

```text
1. exporter 不使用 ports 暴露端口
2. exporter 使用 network_mode: host
3. exporter 只监听 Tailscale IP
4. Prometheus / Grafana / Alertmanager 只监听 127.0.0.1
5. Grafana 通过 Nginx HTTPS 反代访问
6. Prometheus 通过 Tailscale IP 采集所有机器
7. 公网安全组 / UFW 不开放 9100、9115、8080、9090、9093
```

不要这样写：

```yaml
ports:
  - "9100:9100"
  - "9115:9115"
  - "8080:8080"
```

也不要在被监控机器上这样写：

```yaml
ports:
  - "127.0.0.1:9100:9100"
```

因为 `127.0.0.1` 只允许本机访问，中心 Prometheus 无法跨机器采集。

本方案使用：

```yaml
network_mode: host
```

并让 exporter 监听：

```text
TailscaleIP:9100
TailscaleIP:9115
TailscaleIP:8080
```

------

# 一、被监控服务器部署 monitor-agent

每台被监控服务器都需要部署：

```text
node_exporter      主机指标
blackbox_exporter  网络探测
cAdvisor           Docker 容器指标
```

------

## 1. 安装并登录 Tailscale

在每台被监控服务器上确认 Tailscale 可用：

```bash
tailscale status
```

查看本机 Tailscale IPv4：

```bash
tailscale ip -4
```

示例：

```text
100.85.140.54
```

------

## 2. 创建 agent 目录

```bash
mkdir -p ~/monitor-agent/blackbox
cd ~/monitor-agent
```

生成 `.env`：

```bash
echo "TS_IP=$(tailscale ip -4 | head -n1)" > .env
cat .env
```

示例：

```env
TS_IP=100.85.140.54
```

------

## 3. 创建 agent 的 docker-compose.yml

```bash
vim docker-compose.yml
```

写入：

```yaml
services:
  node_exporter:
    image: prom/node-exporter:latest
    container_name: node_exporter
    restart: unless-stopped
    network_mode: host
    pid: host
    command:
      - "--path.rootfs=/host"
      - "--web.listen-address=${TS_IP}:9100"
    volumes:
      - "/:/host:ro,rslave"

  blackbox_exporter:
    image: prom/blackbox-exporter:latest
    container_name: blackbox_exporter
    restart: unless-stopped
    network_mode: host
    cap_add:
      - NET_RAW
    command:
      - "--config.file=/etc/blackbox_exporter/blackbox.yml"
      - "--web.listen-address=${TS_IP}:9115"
    volumes:
      - "./blackbox/blackbox.yml:/etc/blackbox_exporter/blackbox.yml:ro"

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:latest
    container_name: cadvisor
    restart: unless-stopped
    network_mode: host
    privileged: true
    command:
      - "--listen_ip=${TS_IP}"
      - "--port=8080"
      - "--docker_only=true"
    volumes:
      - "/:/rootfs:ro"
      - "/var/run:/var/run:ro"
      - "/sys:/sys:ro"
      - "/var/lib/docker/:/var/lib/docker:ro"
      - "/dev/disk/:/dev/disk:ro"
```

说明：

```text
node_exporter 监听：TailscaleIP:9100
blackbox_exporter 监听：TailscaleIP:9115
cAdvisor 监听：TailscaleIP:8080
```

这里没有 `ports:`，不会把端口发布到公网。

------

## 4. 创建 blackbox 配置

```bash
vim blackbox/blackbox.yml
```

写入：

```yaml
modules:
  http_2xx:
    prober: http
    timeout: 5s
    http:
      method: GET
      preferred_ip_protocol: "ip4"
      valid_status_codes: []

  https_2xx:
    prober: http
    timeout: 5s
    http:
      method: GET
      preferred_ip_protocol: "ip4"
      fail_if_not_ssl: true
      valid_status_codes: []

  tcp_connect:
    prober: tcp
    timeout: 5s
    tcp:
      preferred_ip_protocol: "ip4"

  icmp_ping:
    prober: icmp
    timeout: 5s
    icmp:
      preferred_ip_protocol: "ip4"

  dns_check:
    prober: dns
    timeout: 5s
    dns:
      preferred_ip_protocol: "ip4"
      query_name: "www.baidu.com"
      query_type: "A"
```

------

## 5. 启动 agent

```bash
cd ~/monitor-agent
docker compose up -d
```

查看状态：

```bash
docker compose ps
```

查看监听端口：

```bash
ss -lntp | grep -E '9100|9115|8080'
```

期望看到：

```text
100.x.x.x:9100
100.x.x.x:9115
100.x.x.x:8080
```

不应该看到：

```text
0.0.0.0:9100
0.0.0.0:9115
0.0.0.0:8080
```

------

## 6. 本机验证 agent

```bash
curl http://$(tailscale ip -4 | head -n1):9100/metrics | head
curl http://$(tailscale ip -4 | head -n1):9115/metrics | head
curl http://$(tailscale ip -4 | head -n1):8080/metrics | head
```

验证 blackbox：

```bash
curl "http://$(tailscale ip -4 | head -n1):9115/probe?target=https://www.baidu.com&module=http_2xx" | grep probe_success
```

正常结果：

```text
probe_success 1
```

------

# 二、中心监控机部署

中心监控机部署：

```text
Prometheus
Grafana
Alertmanager
servers.txt
gen-targets.sh
```

------

## 1. 创建目录结构

```bash
mkdir -p ~/monitoring/{prometheus/rules,prometheus/targets,grafana/provisioning/datasources,grafana/data,alertmanager,probes,data/prometheus,data/alertmanager}
cd ~/monitoring
```

最终目录大致如下：

```text
~/monitoring
├── docker-compose.yml
├── servers.txt
├── gen-targets.sh
├── probes
│   ├── http_targets.txt
│   ├── icmp_targets.txt
│   └── tcp_targets.txt
├── prometheus
│   ├── prometheus.yml
│   ├── rules
│   │   └── alerts.yml
│   └── targets
│       ├── nodes.yml
│       ├── cadvisor.yml
│       ├── blackbox-exporters.yml
│       ├── blackbox_http.yml
│       ├── blackbox_icmp.yml
│       └── blackbox_tcp.yml
├── grafana
│   ├── data
│   └── provisioning
│       └── datasources
│           └── datasource.yml
├── alertmanager
│   └── alertmanager.yml
└── data
    ├── prometheus
    └── alertmanager
```

------

## 2. 创建中心监控机 docker-compose.yml

```bash
vim docker-compose.yml
```

写入：

```yaml
services:
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    restart: unless-stopped
    user: "0:0"
    network_mode: host
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.path=/prometheus"
      - "--storage.tsdb.retention.time=30d"
      - "--web.listen-address=127.0.0.1:9090"
      - "--web.enable-lifecycle"
    volumes:
      - "./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro"
      - "./prometheus/rules:/etc/prometheus/rules:ro"
      - "./prometheus/targets:/etc/prometheus/targets:ro"
      - "./data/prometheus:/prometheus"

  grafana:
    image: grafana/grafana-oss:latest
    container_name: grafana
    restart: unless-stopped
    network_mode: host
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=ChangeMe_123456
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_SERVER_HTTP_ADDR=127.0.0.1
      - GF_SERVER_HTTP_PORT=3000
      - GF_SERVER_ROOT_URL=https://monitor.yypan.cloud
      - GF_METRICS_ENABLED=true
    volumes:
      - "./grafana/data:/var/lib/grafana"
      - "./grafana/provisioning:/etc/grafana/provisioning:ro"
    depends_on:
      - prometheus

  alertmanager:
    image: prom/alertmanager:latest
    container_name: alertmanager
    restart: unless-stopped
    network_mode: host
    command:
      - "--config.file=/etc/alertmanager/alertmanager.yml"
      - "--storage.path=/alertmanager"
      - "--web.listen-address=127.0.0.1:9093"
      - "--cluster.listen-address="
    volumes:
      - "./alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro"
      - "./data/alertmanager:/alertmanager"
```

注意：

```yaml
- "--cluster.listen-address="
```

表示关闭 Alertmanager 单机部署不需要的集群 gossip 端口 `9094`。

------

## 3. 设置 Grafana 数据目录权限

Grafana 容器默认用户通常没有权限写宿主机目录，所以需要调整：

```bash
cd ~/monitoring

sudo mkdir -p grafana/data
sudo chown -R 472:472 grafana/data
sudo chmod -R u+rwX grafana/data
```

如果不做这一步，Grafana 可能报错：

```text
GF_PATHS_DATA='/var/lib/grafana' is not writable.
mkdir: can't create directory '/var/lib/grafana/plugins': Permission denied
```

------

## 4. 创建 Grafana Prometheus 数据源

```bash
vim grafana/provisioning/datasources/datasource.yml
```

写入：

```yaml
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9090
    isDefault: true
    editable: true
```

因为 Grafana 和 Prometheus 都使用 `network_mode: host`，所以 Grafana 访问 Prometheus 使用：

```text
http://127.0.0.1:9090
```

------

## 5. 创建 Alertmanager 配置

```bash
vim alertmanager/alertmanager.yml
```

写入基础配置：

```yaml
global:
  resolve_timeout: 5m

route:
  receiver: default
  group_by:
    - alertname
    - instance
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h

receivers:
  - name: default
```

这个配置可以接收告警，但不会发送通知。

后续如果要接 Telegram、企业微信、邮件、Webhook，再改 `receivers`。

------

# 三、Prometheus 配置

## 1. 创建 prometheus.yml

```bash
vim prometheus/prometheus.yml
```

写入：

```yaml
global:
  scrape_interval: 15s
  scrape_timeout: 10s
  evaluation_interval: 15s

rule_files:
  - /etc/prometheus/rules/*.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - "127.0.0.1:9093"

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets:
          - "127.0.0.1:9090"

  - job_name: "alertmanager"
    static_configs:
      - targets:
          - "127.0.0.1:9093"

  - job_name: "grafana"
    static_configs:
      - targets:
          - "127.0.0.1:3000"

  - job_name: "node_exporter"
    file_sd_configs:
      - files:
          - /etc/prometheus/targets/nodes.yml
        refresh_interval: 30s

  - job_name: "cadvisor"
    file_sd_configs:
      - files:
          - /etc/prometheus/targets/cadvisor.yml
        refresh_interval: 30s

  - job_name: "blackbox_exporter"
    file_sd_configs:
      - files:
          - /etc/prometheus/targets/blackbox-exporters.yml
        refresh_interval: 30s

  - job_name: "blackbox_http"
    metrics_path: /probe
    params:
      module: [http_2xx]
    file_sd_configs:
      - files:
          - /etc/prometheus/targets/blackbox_http.yml
        refresh_interval: 30s
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target

      - source_labels: [__address__]
        target_label: instance

      - source_labels: [__address__]
        target_label: target

      - source_labels: [blackbox_address]
        target_label: __address__

  - job_name: "blackbox_icmp"
    metrics_path: /probe
    params:
      module: [icmp_ping]
    file_sd_configs:
      - files:
          - /etc/prometheus/targets/blackbox_icmp.yml
        refresh_interval: 30s
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target

      - source_labels: [__address__]
        target_label: instance

      - source_labels: [__address__]
        target_label: target

      - source_labels: [blackbox_address]
        target_label: __address__

  - job_name: "blackbox_tcp"
    metrics_path: /probe
    params:
      module: [tcp_connect]
    file_sd_configs:
      - files:
          - /etc/prometheus/targets/blackbox_tcp.yml
        refresh_interval: 30s
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target

      - source_labels: [__address__]
        target_label: instance

      - source_labels: [__address__]
        target_label: target

      - source_labels: [blackbox_address]
        target_label: __address__
```

关键点：

```yaml
file_sd_configs:
  - files:
      - /etc/prometheus/targets/nodes.yml
```

Prometheus 不再手动写死每台机器，而是读取自动生成的 target 文件。

------

# 四、维护服务器与探测目标

## 1. 创建 servers.txt

```bash
vim servers.txt
```

格式：

```text
# TailscaleIP      node_name   region   cadvisor
100.85.140.54      jp-01       jp       yes
100.100.100.11     hk-01       hk       yes
100.100.100.12     us-01       us       yes
```

字段说明：

| 字段        | 含义                                |
| ----------- | ----------------------------------- |
| TailscaleIP | 被监控服务器的 Tailscale IPv4       |
| node_name   | 节点名                              |
| region      | 区域，例如 jp、hk、us、sg、cn       |
| cadvisor    | 是否采集 Docker 指标，`yes` 或 `no` |

------

## 2. 创建 HTTP 探测目标

```bash
vim probes/http_targets.txt
```

写入：

```text
# target                         direction
https://www.baidu.com            cn
https://mirrors.aliyun.com        cn
https://cloud.tencent.com         cn
https://github.com                global
https://www.cloudflare.com        global
https://www.google.com            global
https://blog.yypan.cloud          self
https://s3.yypan.cloud            self
```

字段说明：

| 字段      | 含义                            |
| --------- | ------------------------------- |
| target    | 探测目标                        |
| direction | 方向标签，例如 cn、global、self |

------

## 3. 创建 ICMP 探测目标

```bash
vim probes/icmp_targets.txt
```

写入：

```text
# target          direction
223.5.5.5         cn
119.29.29.29      cn
1.1.1.1           global
8.8.8.8           global
```

------

## 4. 创建 TCP 探测目标

```bash
vim probes/tcp_targets.txt
```

写入：

```text
# target                  direction
www.baidu.com:443         cn
mirrors.aliyun.com:443     cn
github.com:443            global
www.cloudflare.com:443    global
blog.yypan.cloud:443      self
s3.yypan.cloud:443        self
```

------

# 五、自动生成 Prometheus targets

## 1. 创建 gen-targets.sh

```bash
vim gen-targets.sh
```

写入：

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-/root/monitoring}"
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
```

------

## 2. 授权并执行

```bash
chmod +x gen-targets.sh
./gen-targets.sh
```

检查生成文件：

```bash
ls -lh prometheus/targets
cat prometheus/targets/nodes.yml
cat prometheus/targets/blackbox_http.yml
```

------

# 六、告警规则

## 1. 创建 alerts.yml

```bash
vim prometheus/rules/alerts.yml
```

写入：

```yaml
groups:
  - name: server-alerts
    rules:
      - alert: ServerDown
        expr: up{job="node_exporter"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "服务器离线: {{ $labels.node }}"
          description: "{{ $labels.node }} / {{ $labels.instance }} 的 node_exporter 已连续 2 分钟不可达。"

      - alert: BlackboxExporterDown
        expr: up{job="blackbox_exporter"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Blackbox Exporter 不可达: {{ $labels.node }}"
          description: "{{ $labels.node }} 的 blackbox_exporter 已连续 2 分钟不可达。"

      - alert: CadvisorDown
        expr: up{job="cadvisor"} == 0
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "cAdvisor 不可达: {{ $labels.node }}"
          description: "{{ $labels.node }} 的 cAdvisor 已连续 2 分钟不可达。"

      - alert: HighCPUUsage
        expr: 100 - (avg by(instance, node) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "CPU 使用率过高: {{ $labels.node }}"
          description: "{{ $labels.node }} CPU 使用率超过 85%，已持续 5 分钟。"

      - alert: HighMemoryUsage
        expr: (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "内存使用率过高: {{ $labels.node }}"
          description: "{{ $labels.node }} 内存使用率超过 85%，已持续 5 分钟。"

      - alert: DiskSpaceLow
        expr: (1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs"}) * 100 > 85
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "磁盘空间不足: {{ $labels.node }}"
          description: "{{ $labels.node }} / {{ $labels.mountpoint }} 磁盘使用率超过 85%。"

  - name: network-alerts
    rules:
      - alert: BlackboxProbeFailed
        expr: probe_success{job=~"blackbox_http|blackbox_icmp|blackbox_tcp"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "网络探测失败: {{ $labels.probe_node }} -> {{ $labels.target }}"
          description: "{{ $labels.probe_node }} 从 {{ $labels.probe_region }} 探测 {{ $labels.target }} 失败，方向：{{ $labels.direction }}。"

      - alert: BlackboxHighLatency
        expr: probe_duration_seconds{job=~"blackbox_http|blackbox_icmp|blackbox_tcp"} > 2
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "网络延迟较高: {{ $labels.probe_node }} -> {{ $labels.target }}"
          description: "{{ $labels.probe_node }} 探测 {{ $labels.target }} 耗时超过 2 秒，方向：{{ $labels.direction }}。"

      - alert: SSLCertExpiringSoon
        expr: probe_ssl_earliest_cert_expiry - time() < 86400 * 7
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "SSL 证书即将过期: {{ $labels.target }}"
          description: "{{ $labels.target }} 的 SSL 证书将在 7 天内过期。"
```

------

# 七、启动中心监控服务

## 1. 生成 targets

```bash
cd ~/monitoring
./gen-targets.sh
```

------

## 2. 启动服务

```bash
docker compose up -d
```

查看状态：

```bash
docker compose ps
```

------

## 3. 检查 Prometheus 配置

```bash
docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
```

如果返回成功，说明配置语法没问题。

------

## 4. 检查本机监听端口

```bash
ss -lntp | grep -E '9090|9093|3000|9094'
```

期望看到：

```text
127.0.0.1:9090
127.0.0.1:9093
127.0.0.1:3000
```

不应该看到：

```text
0.0.0.0:9090
0.0.0.0:9093
0.0.0.0:3000
0.0.0.0:9094
```

如果看到 `9094`，说明 Alertmanager 没有正确关闭 cluster 端口，需要确认是否有：

```yaml
- "--cluster.listen-address="
```

------

# 八、验证采集是否正常

## 1. 中心机直接 curl 被监控节点

假设被监控节点 Tailscale IP 是：

```text
100.85.140.54
```

执行：

```bash
curl http://100.85.140.54:9100/metrics | head
curl http://100.85.140.54:9115/metrics | head
curl http://100.85.140.54:8080/metrics | head
```

验证 blackbox：

```bash
curl "http://100.85.140.54:9115/probe?target=https://www.baidu.com&module=http_2xx" | grep probe_success
```

验证 ICMP：

```bash
curl "http://100.85.140.54:9115/probe?target=1.1.1.1&module=icmp_ping" | grep probe_success
```

------

## 2. 访问 Prometheus

因为 Prometheus 只监听 `127.0.0.1:9090`，需要 SSH 隧道：

```bash
ssh -L 9090:127.0.0.1:9090 root@中心监控机公网IP
```

本地浏览器打开：

```text
http://127.0.0.1:9090
```

查看 targets：

```text
http://127.0.0.1:9090/targets
```

应该能看到这些 job：

```text
prometheus
alertmanager
grafana
node_exporter
cadvisor
blackbox_exporter
blackbox_http
blackbox_icmp
blackbox_tcp
```

------

## 3. Prometheus 查询验证

查询全部在线状态：

```promql
up
```

查询主机 exporter：

```promql
up{job="node_exporter"}
```

查询 blackbox exporter：

```promql
up{job="blackbox_exporter"}
```

查询 HTTP 探测：

```promql
probe_success{job="blackbox_http"}
```

查询 ICMP 探测：

```promql
probe_success{job="blackbox_icmp"}
```

查询 TCP 探测：

```promql
probe_success{job="blackbox_tcp"}
```

检查 blackbox 标签是否完整：

```promql
probe_success{job=~"blackbox_http|blackbox_icmp|blackbox_tcp"}
```

结果里应该包含：

```text
target
direction
probe_node
probe_region
```

示例：

```text
probe_success{
  job="blackbox_http",
  target="https://www.baidu.com",
  direction="cn",
  probe_node="jp-01",
  probe_region="jp"
} 1
```

------

# 九、Nginx 反代 Grafana

假设域名是：

```text
monitor.yypan.cloud
```

Grafana 本身只监听：

```text
127.0.0.1:3000
```

创建 Nginx 配置：

```nginx
server {
    listen 80;
    server_name monitor.yypan.cloud;

    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name monitor.yypan.cloud;

    ssl_certificate /etc/letsencrypt/live/monitor.yypan.cloud/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/monitor.yypan.cloud/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:3000;

        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

检查并重载：

```bash
nginx -t
systemctl reload nginx
```

------

# 十、防火墙配置

## 1. 被监控服务器 UFW

```bash
ufw default deny incoming
ufw default allow outgoing

ufw allow in on tailscale0
ufw allow OpenSSH

ufw enable
ufw status verbose
```

如果这台机器还提供公网 Web 服务：

```bash
ufw allow 80/tcp
ufw allow 443/tcp
```

不要开放：

```bash
ufw allow 9100/tcp
ufw allow 9115/tcp
ufw allow 8080/tcp
```

------

## 2. 中心监控机 UFW

```bash
ufw default deny incoming
ufw default allow outgoing

ufw allow in on tailscale0
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp

ufw enable
ufw status verbose
```

不要开放：

```text
9090 Prometheus
9093 Alertmanager
3000 Grafana 原始端口
```

这三个端口只监听 `127.0.0.1`。

------

# 十一、新增一台服务器

假设新增一台新加坡服务器。

## 1. 新机器加入 Tailscale

```bash
tailscale up
tailscale ip -4
```

假设得到：

```text
100.100.100.20
```

------

## 2. 新机器部署 agent

```bash
mkdir -p ~/monitor-agent/blackbox
cd ~/monitor-agent

echo "TS_IP=$(tailscale ip -4 | head -n1)" > .env
```

复制 agent 的：

```text
docker-compose.yml
blackbox/blackbox.yml
```

启动：

```bash
docker compose up -d
```

检查监听：

```bash
ss -lntp | grep -E '9100|9115|8080'
```

------

## 3. 中心监控机添加 servers.txt

```bash
cd ~/monitoring
vim servers.txt
```

新增：

```text
100.100.100.20     sg-01       sg       yes
```

重新生成 targets：

```bash
./gen-targets.sh
```

Prometheus 会通过 `file_sd_configs` 自动刷新，一般不需要重启。

如果想强制 reload：

```bash
curl -X POST http://127.0.0.1:9090/-/reload
```

------

# 十二、删除一台服务器

编辑：

```bash
cd ~/monitoring
vim servers.txt
```

删除对应行。

重新生成：

```bash
./gen-targets.sh
```

Prometheus 会自动移除 target。

------

# 十三、修改探测目标

修改 HTTP 探测目标：

```bash
vim probes/http_targets.txt
```

修改 ICMP 探测目标：

```bash
vim probes/icmp_targets.txt
```

修改 TCP 探测目标：

```bash
vim probes/tcp_targets.txt
```

然后重新生成：

```bash
./gen-targets.sh
```

Prometheus 会自动刷新。

------

# 十四、常用维护命令

## 1. 查看容器状态

```bash
docker compose ps
```

## 2. 查看日志

```bash
docker logs -f prometheus
docker logs -f grafana
docker logs -f alertmanager
```

agent 机器上：

```bash
docker logs -f node_exporter
docker logs -f blackbox_exporter
docker logs -f cadvisor
```

## 3. 检查 Prometheus 配置

```bash
docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
```

## 4. 重载 Prometheus

```bash
curl -X POST http://127.0.0.1:9090/-/reload
```

如果失败：

```bash
docker compose restart prometheus
```

## 5. 重启 Grafana

```bash
docker compose restart grafana
```

## 6. 重置 Grafana admin 密码

```bash
docker exec -it grafana grafana cli \
  --homepath /usr/share/grafana \
  admin reset-admin-password 'NewStrongPassword'
```

注意：`GF_SECURITY_ADMIN_PASSWORD` 通常只在 Grafana 首次初始化数据库时生效。
如果 `grafana/data` 已经初始化过，修改环境变量不会覆盖已有密码。

------

# 十五、数据备份与迁移

本方案已经把重要数据放到宿主机目录：

```text
~/monitoring/data/prometheus
~/monitoring/data/alertmanager
~/monitoring/grafana/data
```

备份整个监控目录：

```bash
cd ~
tar -czf monitoring-backup.tar.gz monitoring
```

迁移到新机器：

```bash
scp monitoring-backup.tar.gz root@新机器IP:/root/
```

新机器上：

```bash
cd /root
tar -xzf monitoring-backup.tar.gz
cd monitoring
docker compose up -d
```

如果 Tailscale IP、域名、证书路径不变，迁移会比较平滑。

------

# 十六、常见问题排查

## 1. Grafana 报权限错误

错误：

```text
GF_PATHS_DATA='/var/lib/grafana' is not writable.
mkdir: can't create directory '/var/lib/grafana/plugins': Permission denied
```

修复：

```bash
cd ~/monitoring

sudo chown -R 472:472 grafana/data
sudo chmod -R u+rwX grafana/data

docker compose restart grafana
```

------

## 2. Alertmanager 报 9094 冲突

错误：

```text
failed to start TCP listener on "0.0.0.0" port 9094
```

确认 `docker-compose.yml` 中有：

```yaml
- "--cluster.listen-address="
```

然后重启：

```bash
docker compose restart alertmanager
```

检查：

```bash
ss -lntp | grep -E '9093|9094'
```

正常应该只看到：

```text
127.0.0.1:9093
```

------

## 3. Prometheus targets 是 DOWN

查看 targets 页面：

```text
http://127.0.0.1:9090/targets
```

检查错误原因。

常见原因：

```text
1. agent 没启动
2. Tailscale IP 写错
3. Tailscale ACL / 防火墙拦截
4. exporter 没监听 Tailscale IP
5. servers.txt 写错
6. gen-targets.sh 没执行
```

中心监控机直接测试：

```bash
curl http://目标TailscaleIP:9100/metrics | head
curl http://目标TailscaleIP:9115/metrics | head
curl http://目标TailscaleIP:8080/metrics | head
```

------

## 4. Blackbox 没数据

查询：

```promql
probe_success
```

如果没有数据，检查：

```bash
cat prometheus/targets/blackbox_http.yml
cat prometheus/targets/blackbox_icmp.yml
cat prometheus/targets/blackbox_tcp.yml
```

检查 Prometheus targets 页面里是否有：

```text
blackbox_http
blackbox_icmp
blackbox_tcp
```

也可以直接查 API：

```bash
curl -s 'http://127.0.0.1:9090/api/v1/query?query=probe_success' | jq
```

------

## 5. ICMP 探测失败

先在 agent 机器上测试：

```bash
curl "http://$(tailscale ip -4 | head -n1):9115/probe?target=1.1.1.1&module=icmp_ping" | grep probe_success
```

如果失败，看日志：

```bash
docker logs blackbox_exporter
```

确认 agent compose 中有：

```yaml
cap_add:
  - NET_RAW
```

------

## 6. exporter 意外监听 0.0.0.0

检查：

```bash
ss -lntp | grep -E '9100|9115|8080'
```

如果看到：

```text
0.0.0.0:9100
```

说明服务监听了所有网卡，需要确认 `.env` 是否正确：

```bash
cat ~/monitor-agent/.env
```

应该是：

```env
TS_IP=100.x.x.x
```

然后重启：

```bash
cd ~/monitor-agent
docker compose up -d
```

------

# 十七、最终维护方式总结

日常你只需要维护这几个文件：

```text
servers.txt
probes/http_targets.txt
probes/icmp_targets.txt
probes/tcp_targets.txt
gen-targets.sh
prometheus/rules/alerts.yml
```

新增服务器流程：

```bash
# 新服务器
tailscale up
cd ~/monitor-agent
echo "TS_IP=$(tailscale ip -4 | head -n1)" > .env
docker compose up -d

# 中心监控机
cd ~/monitoring
vim servers.txt
./gen-targets.sh
```

修改探测目标流程：

```bash
cd ~/monitoring
vim probes/http_targets.txt
vim probes/icmp_targets.txt
vim probes/tcp_targets.txt
./gen-targets.sh
```

检查 Prometheus：

```bash
docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
```

一句话总结：

```text
中心 Prometheus 通过 Tailscale 采集所有节点；
节点 exporter 只监听 Tailscale IP；
Prometheus targets 由 servers.txt + gen-targets.sh 自动生成；
Grafana 只通过 Nginx HTTPS 反代访问；
监控端口不暴露公网。
```