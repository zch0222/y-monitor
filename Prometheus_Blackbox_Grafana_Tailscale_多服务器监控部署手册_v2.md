# Prometheus + Blackbox Exporter + Grafana + Tailscale 多服务器监控部署手册（v2 修订版）

## 0. v2 修订说明

本版本相对原稿做了以下修订：

```text
[关键修复]
1. SSL 证书告警表达式增加 "> 0" 条件，避免目标未启用 SSL 时持续误报
2. node_exporter 增加 /proc 和 /sys 显式挂载，增加 mount-points-exclude
3. blackbox http_2xx 模块的 valid_status_codes 显式列出，避免空数组带来的歧义
4. Prometheus relabel 末尾增加 labeldrop，丢弃冗余的 blackbox_address 标签
5. Nginx 反代使用 map $http_upgrade $connection_upgrade，规范 WebSocket 处理

[次要优化]
6. cAdvisor 镜像固定版本（v0.49.2），增加性能调优参数
7. Grafana 增加安全 cookie / SameSite 配置
8. 所有容器统一设置 TZ=Asia/Shanghai
9. BlackboxHighLatency 告警按 direction 分级（domestic / global）
10. 强化 UFW 启用顺序的安全警告
11. Alertmanager 章节明确说明 "当前配置不会发送任何通知"
```

------

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

写入（注意 v2 修订）：

```yaml
services:
  node_exporter:
    image: prom/node-exporter:latest
    container_name: node_exporter
    restart: unless-stopped
    network_mode: host
    pid: host
    environment:
      - TZ=Asia/Shanghai
    command:
      - "--path.rootfs=/host"
      - "--path.procfs=/host/proc"
      - "--path.sysfs=/host/sys"
      - "--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc|rootfs|var/lib/docker/.+|var/lib/kubelet/.+)($$|/)"
      - "--collector.filesystem.fs-types-exclude=^(autofs|binfmt_misc|bpf|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|iso9660|mqueue|nsfs|overlay|proc|procfs|pstore|rpc_pipefs|securityfs|selinuxfs|squashfs|sysfs|tracefs)$$"
      - "--web.listen-address=${TS_IP}:9100"
    volumes:
      - "/:/host:ro,rslave"
      - "/proc:/host/proc:ro"
      - "/sys:/host/sys:ro"

  blackbox_exporter:
    image: prom/blackbox-exporter:latest
    container_name: blackbox_exporter
    restart: unless-stopped
    network_mode: host
    environment:
      - TZ=Asia/Shanghai
    cap_add:
      - NET_RAW
    command:
      - "--config.file=/etc/blackbox_exporter/blackbox.yml"
      - "--web.listen-address=${TS_IP}:9115"
    volumes:
      - "./blackbox/blackbox.yml:/etc/blackbox_exporter/blackbox.yml:ro"

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.49.2
    container_name: cadvisor
    restart: unless-stopped
    network_mode: host
    privileged: true
    environment:
      - TZ=Asia/Shanghai
    command:
      - "--listen_ip=${TS_IP}"
      - "--port=8080"
      - "--docker_only=true"
      - "--housekeeping_interval=15s"
      - "--disable_metrics=disk,percpu,sched,tcp,udp,advtcp,process,hugetlb,referenced_memory,cpu_topology,resctrl"
    volumes:
      - "/:/rootfs:ro"
      - "/var/run:/var/run:ro"
      - "/sys:/sys:ro"
      - "/var/lib/docker/:/var/lib/docker:ro"
      - "/dev/disk/:/dev/disk:ro"
```

> **v2 修订说明：**
>
> - `node_exporter` 显式挂载 `/proc` 和 `/sys` 并通过 `--path.procfs` / `--path.sysfs` 指定，避免某些指标采集不准确。
> - `--collector.filesystem.mount-points-exclude` 排除容器层挂载点，避免出现大量无意义的 `/var/lib/docker/...` 文件系统指标。
> - `cAdvisor` 固定版本为 `v0.49.2`（更稳定，多架构支持完善），并通过 `--disable_metrics` 禁用消耗 CPU 较多的指标采集器。
> - 所有容器统一设置 `TZ=Asia/Shanghai`，让日志时间戳与本地一致。
> - `$$` 是 docker compose 转义，最终传给容器的是单个 `$`。

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

写入（注意 v2 修订）：

```yaml
modules:
  http_2xx:
    prober: http
    timeout: 5s
    http:
      method: GET
      preferred_ip_protocol: "ip4"
      valid_status_codes: [200, 201, 202, 204, 301, 302, 304]
      follow_redirects: true
      fail_if_ssl: false

  https_2xx:
    prober: http
    timeout: 5s
    http:
      method: GET
      preferred_ip_protocol: "ip4"
      valid_status_codes: [200, 201, 202, 204, 301, 302, 304]
      fail_if_not_ssl: true
      follow_redirects: true

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

> **v2 修订说明：**
>
> 原稿使用 `valid_status_codes: []`（空数组），blackbox 默认会按 2xx 处理，但写法不直观，且默认不接受 301/302。修订版显式列出常见的成功状态码，并显式开启 `follow_redirects: true`，让重定向类 URL（如不少 CDN 入口）也被正确判定为成功。

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
mkdir -p ~/monitoring/{prometheus/rules,prometheus/targets,grafana/provisioning/datasources,grafana/provisioning/dashboards,grafana/dashboards,grafana/data,alertmanager,probes,data/prometheus,data/alertmanager}
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
│   ├── dashboards
│   │   └── multi-server-monitoring.json
│   └── provisioning
│       ├── dashboards
│       │   └── dashboards.yml
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

写入（注意 v2 修订）：

```yaml
services:
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    restart: unless-stopped
    user: "0:0"
    network_mode: host
    environment:
      - TZ=Asia/Shanghai
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
      - TZ=Asia/Shanghai
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=ChangeMe_123456
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_SERVER_HTTP_ADDR=127.0.0.1
      - GF_SERVER_HTTP_PORT=3000
      - GF_SERVER_ROOT_URL=https://monitor.yypan.cloud
      - GF_SERVER_ENFORCE_DOMAIN=false
      - GF_SECURITY_COOKIE_SECURE=true
      - GF_SECURITY_COOKIE_SAMESITE=lax
      - GF_METRICS_ENABLED=true
    volumes:
      - "./grafana/data:/var/lib/grafana"
      - "./grafana/provisioning:/etc/grafana/provisioning:ro"
      - "./grafana/dashboards:/var/lib/grafana/dashboards:ro"
    depends_on:
      - prometheus

  alertmanager:
    image: prom/alertmanager:latest
    container_name: alertmanager
    restart: unless-stopped
    network_mode: host
    environment:
      - TZ=Asia/Shanghai
    command:
      - "--config.file=/etc/alertmanager/alertmanager.yml"
      - "--storage.path=/alertmanager"
      - "--web.listen-address=127.0.0.1:9093"
      - "--cluster.listen-address="
    volumes:
      - "./alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro"
      - "./data/alertmanager:/alertmanager"
```

> **v2 修订说明：**
>
> - 所有容器统一加 `TZ=Asia/Shanghai`。
> - Grafana 在 HTTPS 反代场景下增加 `GF_SECURITY_COOKIE_SECURE=true` 和 `GF_SECURITY_COOKIE_SAMESITE=lax`，提升 cookie 安全性。
> - Grafana 增加 `./grafana/dashboards` 卷挂载，配合后续的 dashboard provisioning，支持 JSON 文件方式预置仪表盘。

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

## 5. 创建 Grafana Dashboard provisioning 配置（v2 新增）

```bash
vim grafana/provisioning/dashboards/dashboards.yml
```

写入：

```yaml
apiVersion: 1

providers:
  - name: 'default'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
```

随后把仪表盘 JSON 文件放到：

```text
~/monitoring/grafana/dashboards/multi-server-monitoring.json
```

Grafana 启动后会自动加载该目录下所有 JSON 文件作为仪表盘。仪表盘 JSON 文件参见配套的 `multi-server-monitoring.json`。

------

## 6. 创建 Alertmanager 配置

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

> **⚠️ v2 重要提醒：**
>
> 这个配置只是接收告警的"占位配置"，**它不会发送任何通知**。Prometheus 触发的告警会在 Alertmanager 控制台 (`http://127.0.0.1:9093`) 可见，但不会通过任何渠道（邮件 / Telegram / 企业微信 / Webhook）通知到人。
>
> 如果你需要真正收到告警，请把 receivers 改为有效的发送配置，例如 webhook：
>
> ```yaml
> receivers:
>   - name: default
>     webhook_configs:
>       - url: 'http://your-webhook-host/alert'
>         send_resolved: true
> ```

------

# 三、Prometheus 配置

## 1. 创建 prometheus.yml

```bash
vim prometheus/prometheus.yml
```

写入（注意 v2 修订）：

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

      - action: labeldrop
        regex: blackbox_address

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

      - action: labeldrop
        regex: blackbox_address

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

      - action: labeldrop
        regex: blackbox_address
```

> **v2 修订说明：**
>
> 每个 blackbox job 的 `relabel_configs` 末尾都增加了：
>
> ```yaml
> - action: labeldrop
>   regex: blackbox_address
> ```
>
> 这一步在已经把 `blackbox_address` 用作 `__address__` 之后，把它从最终指标里丢掉。否则每条 `probe_*` 指标都会带一个冗余的 `blackbox_address="100.x.x.x:9115"` 标签，徒增存储和查询开销。

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

写入（注意 v2 修订）：

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
        expr: (1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs|nsfs|fuse.*"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs|nsfs|fuse.*"}) * 100 > 85
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

      - alert: BlackboxHighLatencyDomestic
        expr: probe_duration_seconds{job=~"blackbox_http|blackbox_icmp|blackbox_tcp", direction=~"cn|self"} > 1.5
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "国内 / 自有线路延迟较高: {{ $labels.probe_node }} -> {{ $labels.target }}"
          description: "{{ $labels.probe_node }} 探测 {{ $labels.target }} 耗时超过 1.5 秒，方向：{{ $labels.direction }}。"

      - alert: BlackboxHighLatencyGlobal
        expr: probe_duration_seconds{job=~"blackbox_http|blackbox_icmp|blackbox_tcp", direction="global"} > 4
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "国际线路延迟较高: {{ $labels.probe_node }} -> {{ $labels.target }}"
          description: "{{ $labels.probe_node }} 探测 {{ $labels.target }} 耗时超过 4 秒，方向：global。"

      - alert: SSLCertExpiringSoon
        expr: probe_ssl_earliest_cert_expiry{job="blackbox_http"} > 0
              and (probe_ssl_earliest_cert_expiry{job="blackbox_http"} - time()) < 86400 * 7
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "SSL 证书即将过期: {{ $labels.target }}"
          description: "{{ $labels.target }} 的 SSL 证书将在 7 天内过期。"

      - alert: SSLCertExpired
        expr: probe_ssl_earliest_cert_expiry{job="blackbox_http"} > 0
              and (probe_ssl_earliest_cert_expiry{job="blackbox_http"} - time()) < 0
        for: 10m
        labels:
          severity: critical
        annotations:
          summary: "SSL 证书已过期: {{ $labels.target }}"
          description: "{{ $labels.target }} 的 SSL 证书已经过期，请立即续签。"
```

> **v2 修订说明（关键修复）：**
>
> 1. **SSL 证书告警拆分为两个，并修复误报漏洞：**
>
>    原稿表达式 `probe_ssl_earliest_cert_expiry - time() < 86400 * 7` 在目标未启用 SSL 时（指标值为 0），`0 - time()` 是一个非常大的负数，会**永久触发告警**。
>
>    修订版加了前置条件 `probe_ssl_earliest_cert_expiry > 0`，并限定 `job="blackbox_http"`，只对 HTTPS 目标生效。同时新增了 `SSLCertExpired`（已过期）告警，与"即将过期"区分。
>
> 2. **延迟告警按 direction 分级：**
>
>    原稿统一使用 `> 2 秒`，对跨境（如 jp→cn 或 cn→global）线路过严，会频繁误报。修订版拆分为：
>
>    - 国内 / 自有线路：> 1.5 秒
>    - 国际线路：> 4 秒
>
> 3. **DiskSpaceLow 表达式补充了 `nsfs|fuse.*` 文件系统排除**，避免容器层、FUSE 挂载点带来的噪声。

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

并且**不应该再有** `blackbox_address` 标签（v2 已通过 labeldrop 删除）。

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

## 1. 在 nginx.conf 的 http 块中加 map（v2 新增）

编辑 `/etc/nginx/nginx.conf`，在 `http { ... }` 块内（建议放在所有 `include` 上方）增加：

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
```

> **v2 修订说明：**
>
> 原稿在 server 块里硬编码 `Connection "upgrade"`，对所有请求都强制升级。这虽然不会出错，但不规范——非 WebSocket 请求收到 upgrade 头是冗余的。使用 `map` 后，只有客户端真正发起 WebSocket（带 `Upgrade` 头）时才会启用升级。

## 2. 创建 Grafana 站点配置

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

    # 反代 Grafana 主页面
    location / {
        proxy_pass http://127.0.0.1:3000;

        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
    }

    # 反代 Grafana Live（WebSocket 实时推送，可选但推荐）
    location /api/live/ {
        proxy_pass http://127.0.0.1:3000;

        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
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

> **⚠️ 重要安全提示：**
>
> 如果你正在通过 SSH 公网连接到这台机器进行操作，**务必先确认 `ufw allow OpenSSH` 已添加，再执行 `ufw enable`**。否则一旦 enable，UFW 默认 deny incoming 会立刻断开你正在使用的 SSH 连接，且无法重新连入。
>
> 推荐的安全做法是：先在控制面板（VPS 后台 / 云厂商网页 console）准备好备用入口，再操作 UFW。

```bash
# 1. 先确认这两条命令成功添加规则
ufw default deny incoming
ufw default allow outgoing

ufw allow in on tailscale0
ufw allow OpenSSH

# 2. 然后再 enable
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

同样先 allow OpenSSH 再 enable：

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

## 4. 检查告警规则

```bash
docker exec prometheus promtool check rules /etc/prometheus/rules/alerts.yml
```

## 5. 重载 Prometheus

```bash
curl -X POST http://127.0.0.1:9090/-/reload
```

如果失败：

```bash
docker compose restart prometheus
```

## 6. 重启 Grafana

```bash
docker compose restart grafana
```

## 7. 重置 Grafana admin 密码

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

> **关于备份大小：** Prometheus 30 天的 TSDB 通常占几 GB 到几十 GB，Grafana data 几百 MB。如果迁移时不需要保留历史指标，可以只备份配置（`servers.txt`、`probes/`、`prometheus/`、`alertmanager/`、`grafana/dashboards/`），跳过 `data/` 和 `grafana/data/`。

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

## 7. SSL 告警一直在 firing（v2 新增）

如果你升级前用过原稿 alerts.yml，可能会发现 `SSLCertExpiringSoon` 一直在告警，即使没有任何证书快过期。

原因：原稿表达式在目标未启用 SSL 时会误报。

修复：使用 v2 的告警规则替换 `prometheus/rules/alerts.yml`，然后：

```bash
curl -X POST http://127.0.0.1:9090/-/reload
```

------

## 8. 探测指标里冒出 `blackbox_address` 标签

如果你查询：

```promql
probe_success
```

发现指标里有 `blackbox_address="100.x.x.x:9115"` 标签，说明你的 `prometheus.yml` 没有 v2 的 labeldrop。

修复：在每个 blackbox_* job 的 `relabel_configs` 末尾加：

```yaml
- action: labeldrop
  regex: blackbox_address
```

然后 reload Prometheus。

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
grafana/dashboards/multi-server-monitoring.json
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
docker exec prometheus promtool check rules /etc/prometheus/rules/alerts.yml
```

一句话总结：

```text
中心 Prometheus 通过 Tailscale 采集所有节点；
节点 exporter 只监听 Tailscale IP；
Prometheus targets 由 servers.txt + gen-targets.sh 自动生成；
Grafana 只通过 Nginx HTTPS 反代访问；
监控端口不暴露公网。
```

------

# 附录：v1 → v2 改动一览

| # | 位置 | 原稿 | v2 修订 | 严重程度 |
|---|---|---|---|---|
| 1 | `alerts.yml` SSL 告警 | `probe_ssl_earliest_cert_expiry - time() < 86400 * 7` | 加 `> 0` 前置条件，限定 `job="blackbox_http"`，新增 `SSLCertExpired` | 🔴 关键（误报漏洞） |
| 2 | agent `node_exporter` | 仅 `--path.rootfs=/host` | 增加 `--path.procfs` / `--path.sysfs` 和 mount-points-exclude | 🔴 关键（指标准确性） |
| 3 | `blackbox.yml` | `valid_status_codes: []` | 显式列出 `[200, 201, 202, 204, 301, 302, 304]` + `follow_redirects: true` | 🔴 关键（可读性 + 重定向） |
| 4 | `prometheus.yml` blackbox jobs | 无 labeldrop | 末尾加 `labeldrop blackbox_address` | 🔴 关键（标签污染） |
| 5 | Nginx 反代 | 硬编码 `Connection "upgrade"` | 使用 `map $http_upgrade $connection_upgrade` | 🟡 优化（规范性） |
| 6 | agent `cadvisor` | `latest` 镜像 | 固定 `v0.49.2` + 性能调优参数 | 🟡 优化（稳定性） |
| 7 | 中心机 `grafana` | 无 cookie 安全配置 | 加 `GF_SECURITY_COOKIE_SECURE` 等 | 🟡 优化（安全） |
| 8 | 所有容器 | 默认 UTC | 统一 `TZ=Asia/Shanghai` | 🟡 优化（体验） |
| 9 | `alerts.yml` 延迟告警 | 统一 `> 2 秒` | 按 `direction` 分级（domestic > 1.5s / global > 4s） | 🟡 优化（误报） |
| 10 | UFW 章节 | 简单提示顺序 | 强化警告 + 推荐做法 | 🟡 优化（运维安全） |
| 11 | Alertmanager | 默认配置含糊 | 明确说明 "不会发送任何通知" + 给出 webhook 示例 | 🟡 优化（清晰度） |
| 12 | 新增 | 无 | Grafana dashboard provisioning + 配套 JSON | 🟢 新增（可视化） |
