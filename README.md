# y-monitor

基于 Prometheus + Blackbox Exporter + Grafana + Loki + Promtail + Tailscale 的多服务器监控与容器日志方案。

## 架构

```
                     Tailscale 内网
                          │
┌─────────────────────────┴─────────────────────────┐
│                    中心监控机                        │
│  Prometheus   127.0.0.1:9090                        │
│  Grafana      127.0.0.1:3000  ← Nginx HTTPS 反代    │
│  Alertmanager 127.0.0.1:9093                        │
│  Loki         100.x.x.x:3100  （可选同机部署）        │
└──────────────┬────────────────────┬────────────────┘
               │ Tailscale          │ Tailscale
      100.x.x.11:9100/9115/8080/9080   100.x.x.12:9100/9115/8080/9080
               │                    │
       ┌───────▼──────┐     ┌───────▼──────┐
       │  业务服务器 A  │     │  业务服务器 B  │
       │ node_exporter │     │ node_exporter │
       │ blackbox      │     │ blackbox      │
       │ cAdvisor      │     │ cAdvisor      │
       │ Promtail      │     │ Promtail      │
       └──────────────┘     └──────────────┘
```

Loki 也可以独立部署在日志机上：

```text
业务服务器 Promtail ── Tailscale ── Loki 日志机:3100
中心监控机 Grafana ─── Tailscale ── Loki 日志机:3100
```

**安全原则：** 所有 exporter、Promtail、Loki 只监听 Tailscale IP 或 localhost，监控和日志端口不暴露公网。

## 目录结构

```
y-monitor/
├── monitor-agent/              # 部署到每台被监控服务器
│   ├── .env.example            # 环境变量模板，复制为 .env 使用
│   ├── docker-compose.yml
│   ├── setup.sh
│   ├── blackbox/
│   │   └── blackbox.yml
│   └── promtail/
│       └── config.yml          # Docker 容器日志采集配置
├── loki/                       # 可选：独立 Loki 日志机部署
│   ├── .env.example
│   ├── docker-compose.yml
│   ├── setup.sh
│   ├── smoke-test.sh
│   ├── security-test.sh
│   └── config/
│       └── loki.yml
└── monitoring/                 # 部署到中心监控机
    ├── .env.example            # 环境变量模板，复制为 .env 使用
    ├── docker-compose.yml
    ├── servers.txt             # 维护被监控节点列表
    ├── gen-targets.sh          # 自动生成 Prometheus targets
    ├── setup.sh
    ├── probes/                 # 网络探测目标
    │   ├── http_targets.txt
    │   ├── icmp_targets.txt
    │   └── tcp_targets.txt
    ├── prometheus/
    │   ├── prometheus.yml
    │   ├── rules/alerts.yml
    │   └── targets/            # 由 gen-targets.sh 生成，不纳入版本控制
    ├── grafana/
    │   ├── dashboards/         # 放置 Grafana 仪表盘 JSON 文件
    │   └── provisioning/
    │       ├── dashboards/dashboards.yml
    │       └── datasources/datasource.yml
    ├── alertmanager/
    │   └── alertmanager.yml
    ├── loki/
    │   └── config.yml          # Loki 同机部署配置（docker compose profile）
    └── nginx/
        └── monitor.conf            # Nginx 配置示例，自行复制修改后使用
```

---

## 一、部署 Loki 日志服务

Loki 可以与 `monitoring` 同机部署，也可以分机部署。生产环境推荐分机部署，避免日志写入和 Prometheus TSDB 争抢同一台机器的磁盘与 IO。

### 方案 A：Loki 独立日志机

```bash
scp -r loki/ root@<Loki服务器IP>:~/loki
ssh root@<Loki服务器IP>
cd ~/loki
bash setup.sh
docker compose up -d
bash smoke-test.sh
bash security-test.sh
```

`setup.sh` 会自动写入 Loki 机器的 Tailscale IP，并打印两个后续要用的地址：

```text
LOKI_PUSH_URL=http://<LOKI_TS_IP>:3100/loki/api/v1/push
LOKI_URL=http://<LOKI_TS_IP>:3100
```

其中 `LOKI_PUSH_URL` 填到每台业务机的 `monitor-agent/.env`，`LOKI_URL` 填到中心监控机 `monitoring/.env`。

### 方案 B：Loki 与 monitoring 同机

如果机器规模较小，也可以让中心监控机同时运行 Loki。运行 `monitoring/setup.sh` 时选择：

```text
Loki mode: embedded
```

启动服务时使用：

```bash
docker compose --profile loki up -d
```

同机模式下，`setup.sh` 会自动把 `LOKI_URL` 设置为：

```text
http://<MONITOR_TS_IP>:3100
```

---

## 二、部署被监控服务器（monitor-agent）

每台被监控服务器都需要执行以下步骤。

### 前置条件

- 已安装 Docker 和 Docker Compose
- 已安装并登录 Tailscale（`tailscale status` 正常）
- 已准备好 Loki push 地址：`http://<LOKI_IP>:3100/loki/api/v1/push`

### Docker 日志轮转

每台业务机建议先配置 Docker `json-file` 日志轮转，防止本地容器日志写满系统盘：

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "500m",
    "max-file": "3"
  }
}
```

保存到 `/etc/docker/daemon.json` 后重启 Docker。该配置只影响新创建的容器，业务容器需要重建后生效。

### 步骤

**1. 将 `monitor-agent/` 复制到服务器**

```bash
scp -r monitor-agent/ root@<服务器IP>:~/monitor-agent
```

**2. 运行部署脚本**

```bash
cd ~/monitor-agent
bash setup.sh
```

脚本执行流程：
- 自动读取本机 Tailscale IP
- 若 `.env` 不存在：从 `.env.example` 复制并写入 `TS_IP`、`NODE_NAME`
- 若 `.env` 已存在：仅更新 `TS_IP`，其他自定义值（如 `TZ`、`LOKI_PUSH_URL`）保持不变
- 首次部署会要求填写 `LOKI_PUSH_URL`
- 创建 Promtail positions 数据目录 `data/promtail`
- 检查 Docker socket 和 Docker logging driver
- 启动所有容器（`docker compose up -d`）
- 等待 3 秒后自动验证端口监听，并打印将该节点加入 `servers.txt` 的具体命令

**（可选）自定义时区**

默认时区为 `Asia/Shanghai`。如需修改，在运行 `setup.sh` 之前手动创建 `.env`：

```bash
cp .env.example .env
vim .env   # 修改 TZ
```

这样 `setup.sh` 发现 `.env` 已存在，只会更新 `TS_IP`，`TZ` 和 `LOKI_PUSH_URL` 不会被覆盖。

**给业务容器加日志采集 label**

Promtail 默认只采集带 `logging=promtail` 或 `logging=true` label 的容器。业务应用 compose 示例：

```yaml
services:
  app:
    image: example/app:latest
    labels:
      - "logging=promtail"
```

不建议默认采集所有容器，避免基础设施容器、临时任务和高噪声容器把 Loki 写爆。

**3. 验证**

setup.sh 启动后会自动打印端口监听结果。如需手动验证：

```bash
# 确认监听在 Tailscale IP（不应出现 0.0.0.0）
ss -lntp | grep -E '9100|9115|8080|9080'

# 验证指标可访问
curl -s "http://$(tailscale ip -4 | head -n1):9100/metrics" | head
curl -s "http://$(tailscale ip -4 | head -n1):9115/probe?target=https://www.baidu.com&module=http_2xx" | grep probe_success
curl -fsS "http://$(tailscale ip -4 | head -n1):9080/ready"
```

期望结果：`probe_success 1`

---

## 三、部署中心监控机（monitoring）

### 前置条件

- 已安装 Docker 和 Docker Compose
- 已安装并登录 Tailscale
- 已配置域名 DNS，准备好 SSL 证书（Let's Encrypt 或其他）

### 步骤

**1. 克隆仓库**

```bash
git clone <repo_url> ~/y-monitor
cd ~/y-monitor/monitoring
```

**2. 运行初始化脚本**

```bash
bash setup.sh
```

首次运行时，脚本会交互式提示填写所有配置项并生成 `.env`：

```
========================================
  First-time setup — configure .env
========================================

Timezone for all containers [Asia/Shanghai]:
Grafana admin username [admin]:
Grafana admin password: ****
Confirm password: ****
Grafana public domain (e.g. monitor.example.com): monitor.example.com
Prometheus data retention [30d]:
Loki mode: embedded or external [external]:
External Loki URL (e.g. http://100.x.y.z:3100):
```

`.env` 中各变量说明：

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `TZ` | 所有容器的时区 | `Asia/Shanghai` |
| `GF_ADMIN_USER` | Grafana 管理员用户名 | `admin` |
| `GF_ADMIN_PASSWORD` | Grafana 管理员密码（**务必修改**） | 无 |
| `DOMAIN` | Grafana 公开访问域名 | 无 |
| `PROMETHEUS_RETENTION` | Prometheus 数据保留时长 | `30d` |
| `MONITOR_TS_IP` | 中心监控机 Tailscale IPv4 | 自动获取 |
| `LOKI_MODE` | Loki 部署模式：`embedded` 或 `external` | `external` |
| `LOKI_URL` | Grafana 查询 Loki 的地址 | 无 |
| `LOKI_RETENTION` | Loki 同机部署时的数据保留时长 | `336h` |

后续再次运行 `setup.sh` 会直接加载已有 `.env`，不再提示。

脚本还会依次执行：
- 创建运行时数据目录（`data/prometheus`、`data/alertmanager`、`grafana/data`）
- `LOKI_MODE=embedded` 时创建 `data/loki`
- 修复 Grafana 数据目录权限（`chown 472:472`）
- 生成 Prometheus target 文件（`gen-targets.sh`）

**3. 添加被监控节点**

编辑 `servers.txt`，每行一台节点：

```text
# TailscaleIP      node_name   region   cadvisor
100.85.140.54      jp-01       jp       yes
100.100.100.11     hk-01       hk       yes
```

| 字段 | 说明 |
|------|------|
| TailscaleIP | 被监控服务器的 Tailscale IPv4（`tailscale ip -4`） |
| node_name | 节点名，用于 Grafana 展示和告警 |
| region | 区域标签，如 `jp` `hk` `us` `sg` `cn` |
| cadvisor | 是否采集 Docker 容器指标，`yes` 或 `no` |

修改后重新生成 Prometheus target 文件：

```bash
./gen-targets.sh
```

**4. 配置网络探测目标（可选）**

编辑 `probes/http_targets.txt`，添加要探测的 HTTP 地址：

```text
https://blog.example.com    self
https://s3.example.com      self
```

方向标签：`cn`（国内）、`global`（国际）、`self`（自有服务）

同理可编辑 `probes/icmp_targets.txt` 和 `probes/tcp_targets.txt`，修改后执行 `./gen-targets.sh` 重新生成。

**5. 启动服务**

如果 Loki 独立部署：

```bash
docker compose up -d
docker compose ps
```

如果 Loki 与 monitoring 同机部署：

```bash
docker compose --profile loki up -d
docker compose ps
```

**6. 配置 Nginx**

参考 `nginx/monitor.conf` 示例，将 `monitor.example.com` 替换为实际域名后部署：

```bash
cp nginx/monitor.conf /etc/nginx/conf.d/monitor.conf
vim /etc/nginx/conf.d/monitor.conf   # 替换域名和证书路径
```

在 `/etc/nginx/nginx.conf` 的 `http {}` 块中加入以下内容（二者都需要）：

```nginx
# Grafana 登录限速：每 IP 10 次/分钟
limit_req_zone $binary_remote_addr zone=grafana_login:10m rate=10r/m;

# WebSocket 升级支持（Grafana Live）
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
```

```bash
nginx -t && systemctl reload nginx
```

示例配置已包含以下公网安全强化：

| 项目 | 配置 |
|------|------|
| TLS 版本 | 仅允许 TLSv1.2 / TLSv1.3 |
| 密码套件 | ECDHE/DHE + AEAD，禁用弱密码 |
| HSTS | `max-age=86400; includeSubDomains` |
| 登录限速 | `/login` 每 IP 10 req/min，burst 5 |
| 安全响应头 | `X-Frame-Options`、`X-Content-Type-Options`、`Referrer-Policy` |
| 版本隐藏 | `server_tokens off` |

**7. 验证**

```bash
# 检查 Prometheus 配置语法
docker exec prometheus promtool check config /etc/prometheus/prometheus.yml

# 确认端口只监听 127.0.0.1
ss -lntp | grep -E '9090|9093|3000'

# 验证 Loki datasource 指向的 Loki 可访问
set -a; source .env; set +a
curl -fsS "${LOKI_URL}/ready"
```

访问 Grafana：`https://<DOMAIN>`，使用配置时填写的账号密码登录。

---

## 四、新增服务器

**1. 新服务器安装并启动 agent（参考第一章）**

**2. 中心监控机添加节点**

```bash
cd ~/y-monitor/monitoring
echo "100.100.100.20    sg-01    sg    yes" >> servers.txt
./gen-targets.sh
```

Prometheus 通过 `file_sd_configs` 每 30 秒自动刷新，无需重启。如需立即生效：

```bash
curl -X POST http://127.0.0.1:9090/-/reload
```

## 五、删除服务器

```bash
cd ~/y-monitor/monitoring
vim servers.txt   # 删除对应行
./gen-targets.sh
```

---

## 六、防火墙配置

> **⚠️ 安全提示：** 务必先执行 `ufw allow OpenSSH`，再执行 `ufw enable`，否则会立刻断开 SSH 连接。

**被监控服务器**

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0
ufw allow OpenSSH
ufw allow 80/tcp   # 如有公网 Web 服务
ufw allow 443/tcp
ufw enable
```

不要开放 `9100`、`9115`、`8080`、`9080`。

**中心监控机**

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw enable
```

不要开放 `9090`、`9093`、`3000`。如果 Loki 与 monitoring 同机部署，也不要向公网开放 `3100`。

**独立 Loki 日志机**

```bash
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0 to any port 3100 proto tcp
ufw allow OpenSSH
ufw enable
```

不要向公网开放 `3100`。

---

## 七、测试脚本

每个目录下各有两个测试脚本，部署后运行验证。

### monitor-agent

```bash
cd ~/monitor-agent

# 冒烟测试：验证三个 exporter、Promtail 正常运行
bash smoke-test.sh

# 安全测试：验证端口绑定和配置合规性
bash security-test.sh
```

**smoke-test.sh** 检查项：
- 四个容器（node_exporter / blackbox_exporter / cadvisor / promtail）状态为 running
- HTTP 端点（:9100 / :9115 / :8080 / :9080）返回 200
- Promtail 能访问 Docker socket
- Promtail 能访问 `LOKI_PUSH_URL` 对应的 Loki `/ready`
- blackbox HTTP 探测 https://www.baidu.com → `probe_success 1`
- blackbox ICMP 探测 223.5.5.5 → `probe_success 1`

**security-test.sh** 检查项：
- 端口 9100 / 9115 / 8080 / 9080 未绑定到 `0.0.0.0`（不暴露公网）
- 端口 9100 / 9115 / 8080 / 9080 未绑定到 `127.0.0.1`（确保 Prometheus 可跨机采集）
- 端口 9100 / 9115 / 8080 / 9080 绑定在 Tailscale IP
- `docker-compose.yml` 无 `ports:` 映射
- Promtail Docker socket 只读挂载
- Promtail 使用 `logging` label 做 opt-in 采集
- Promtail 未把 `traceId`、用户 ID、IP、path 等高基数字段提升为 label
- `.env` 未被 git 追踪

### loki

独立 Loki 日志机部署时运行：

```bash
cd ~/loki

# 冒烟测试：验证 Loki 容器和 HTTP API
bash smoke-test.sh

# 安全测试：验证 3100 只监听 Tailscale IP
bash security-test.sh
```

**smoke-test.sh** 检查项：
- `loki` 容器状态为 running
- `http://<LOKI_TS_IP>:3100/ready` 返回 200
- Loki labels API 可访问
- 最近 Loki 日志中无明显启动错误

**security-test.sh** 检查项：
- 端口 3100 未绑定到 `0.0.0.0`
- 端口 3100 绑定在 Loki Tailscale IP
- `docker-compose.yml` 无 `ports:` 映射
- `.env` 未被 git 追踪

### monitoring

```bash
cd ~/y-monitor/monitoring

# 冒烟测试：验证中心监控服务健康且采集正常
bash smoke-test.sh

# 安全测试：验证端口绑定、配置安全性和敏感文件
bash security-test.sh
```

**smoke-test.sh** 检查项：
- 三个容器（prometheus / grafana / alertmanager）状态为 running
- 三个健康接口（`/-/healthy` / `/api/health`）返回 200
- `LOKI_URL/ready` 返回 200
- `LOKI_MODE=embedded` 时本机 `loki` 容器状态为 running
- Grafana Loki datasource 已配置
- `prometheus.yml` 和 `alerts.yml` 语法合法（promtool）
- 六个 target 文件存在且非空
- Prometheus 至少有一个 UP 的 scrape target

**security-test.sh** 检查项：
- 端口 9090 / 9093 / 3000 未绑定到 `0.0.0.0`
- 端口 9090 / 9093 / 3000 绑定在 `127.0.0.1`
- 端口 9094（Alertmanager cluster gossip）未监听
- `LOKI_MODE=embedded` 时 3100 只绑定在 `MONITOR_TS_IP`
- `LOKI_MODE=external` 时本机不应监听 3100
- `LOKI_URL` 使用 Tailscale IP 或 MagicDNS 地址
- `docker-compose.yml` 无 `ports:` 映射
- Prometheus / Alertmanager 监听地址配置正确
- Grafana 禁止公开注册，Cookie 安全标志已开启
- `.env` 未被 git 追踪
- Grafana admin 密码已修改（非默认值）

---

## 八、常用维护命令


```bash
# 查看容器状态
docker compose ps

# 查看日志
docker logs -f prometheus
docker logs -f grafana
docker logs -f alertmanager
docker logs -f loki
docker logs -f promtail

# 校验 Prometheus 配置
docker exec prometheus promtool check config /etc/prometheus/prometheus.yml
docker exec prometheus promtool check rules /etc/prometheus/rules/alerts.yml

# 热重载 Prometheus
curl -X POST http://127.0.0.1:9090/-/reload

# 重置 Grafana admin 密码
# （GF_ADMIN_PASSWORD 仅首次初始化时生效，已有数据目录时需用此命令）
docker exec -it grafana grafana cli \
  --homepath /usr/share/grafana \
  admin reset-admin-password 'NewStrongPassword'
```

---

## 九、告警配置

默认已内置以下告警规则（`prometheus/rules/alerts.yml`）：

| 告警 | 触发条件 |
|------|----------|
| ServerDown | node_exporter 不可达超过 2 分钟 |
| BlackboxExporterDown | blackbox_exporter 不可达超过 2 分钟 |
| CadvisorDown | cAdvisor 不可达超过 2 分钟 |
| HighCPUUsage | CPU 使用率 > 85% 持续 5 分钟 |
| HighMemoryUsage | 内存使用率 > 85% 持续 5 分钟 |
| DiskSpaceLow | 磁盘使用率 > 85% 持续 10 分钟 |
| BlackboxProbeFailed | 网络探测失败超过 2 分钟 |
| BlackboxHighLatencyDomestic | 国内/自有线路延迟 > 1.5 秒持续 5 分钟 |
| BlackboxHighLatencyGlobal | 国际线路延迟 > 4 秒持续 5 分钟 |
| SSLCertExpiringSoon | SSL 证书 7 天内到期 |
| SSLCertExpired | SSL 证书已过期 |

> **注意：** 默认 `alertmanager/alertmanager.yml` 中 `receivers` 为空占位配置，**不会发送任何通知**。如需接收告警，编辑该文件配置 Webhook、Telegram 或邮件，然后重启：`docker compose restart alertmanager`

---

## 十、数据保留配置

Prometheus 默认将采集到的时序数据存储在 `monitoring/data/prometheus/` 目录，保留时长由 `.env` 中的 `PROMETHEUS_RETENTION` 控制，最终传递给容器启动参数 `--storage.tsdb.retention.time`。

Loki 默认将日志数据存储在 `monitoring/data/loki/` 或独立日志机的 `loki/data/` 目录，保留时长由 `LOKI_RETENTION` 控制。默认值 `336h` 表示 14 天。

### 修改保留时长

编辑 `.env`：

```bash
vim ~/y-monitor/monitoring/.env
```

修改 `PROMETHEUS_RETENTION`，支持的单位：

| 单位 | 示例 | 说明 |
|------|------|------|
| `d` | `30d` | 天（最常用） |
| `w` | `4w` | 周 |
| `y` | `1y` | 年 |
| `h` | `72h` | 小时 |

修改后重启 Prometheus 生效：

```bash
cd ~/y-monitor/monitoring
docker compose restart prometheus
```

修改 Loki 保留时长后重启 Loki 生效：

```bash
docker compose restart loki
```

### 磁盘占用估算

实际占用取决于节点数量、采集频率和指标数量，以下为大致参考：

| 节点数 | 保留时长 | 估算占用 |
|--------|----------|----------|
| 3 节点 | 30d | 2 ~ 5 GB |
| 3 节点 | 90d | 6 ~ 15 GB |
| 10 节点 | 30d | 8 ~ 20 GB |

可以用以下命令查看当前实际占用：

```bash
du -sh ~/y-monitor/monitoring/data/prometheus/
du -sh ~/y-monitor/monitoring/data/loki/  # Loki 同机部署
du -sh ~/loki/data/                       # Loki 分机部署
```

### 注意事项

- 缩短保留时长（如从 `90d` 改为 `30d`）并重启后，Prometheus 会在后台逐步清理过期数据块，**不会立即释放磁盘空间**，通常在数小时到一天内完成。
- 如果磁盘空间紧张需要立即释放，可以停止容器后手动删除 `data/prometheus/` 下的旧数据块目录（文件名为 26 位 ULID 格式），但会丢失对应时段的历史数据。
- Prometheus 没有按指标类型单独设置保留时长的选项，所有 job 的数据共用同一个保留策略。

---

## 十一、数据备份与迁移

```bash
cd ~
tar -czf monitoring-backup.tar.gz y-monitor/monitoring/data y-monitor/monitoring/grafana/data

# Loki 分机部署时，在 Loki 主机单独备份
tar -czf loki-backup.tar.gz loki/data loki/config loki/.env
```

迁移到新机器：

```bash
scp monitoring-backup.tar.gz root@新机器IP:/root/
ssh root@新机器IP
cd /root && tar -xzf monitoring-backup.tar.gz
cd y-monitor/monitoring && docker compose up -d
```

> Prometheus 30 天 TSDB 通常占几 GB 到几十 GB，Loki 占用取决于业务日志量和 `LOKI_RETENTION`。若无需保留历史数据，可只备份配置文件（`servers.txt`、`probes/`、`prometheus/`、`alertmanager/`、`grafana/dashboards/`、`loki/config/`、`.env`），跳过 `data/` 和 `grafana/data/`。
