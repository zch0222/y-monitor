# y-monitor

基于 Prometheus + Blackbox Exporter + Grafana + Tailscale 的多服务器监控方案。

## 架构

```
                     Tailscale 内网
                          │
┌─────────────────────────┴─────────────────────────┐
│                    中心监控机                        │
│  Prometheus   127.0.0.1:9090                        │
│  Grafana      127.0.0.1:3000  ← Nginx HTTPS 反代    │
│  Alertmanager 127.0.0.1:9093                        │
└──────────────┬────────────────────┬────────────────┘
               │ Tailscale          │ Tailscale
      100.x.x.11:9100/9115/8080   100.x.x.12:9100/9115/8080
               │                    │
       ┌───────▼──────┐     ┌───────▼──────┐
       │  业务服务器 A  │     │  业务服务器 B  │
       │ node_exporter │     │ node_exporter │
       │ blackbox      │     │ blackbox      │
       │ cAdvisor      │     │ cAdvisor      │
       └──────────────┘     └──────────────┘
```

**安全原则：** 所有 exporter 只监听 Tailscale IP，监控端口不暴露公网。

## 目录结构

```
y-monitor/
├── monitor-agent/              # 部署到每台被监控服务器
│   ├── .env.example            # 环境变量模板，复制为 .env 使用
│   ├── docker-compose.yml
│   ├── setup.sh
│   └── blackbox/
│       └── blackbox.yml
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
    └── nginx/
        └── monitor.conf            # Nginx 配置示例，自行复制修改后使用
```

---

## 一、部署被监控服务器（monitor-agent）

每台被监控服务器都需要执行以下步骤。

### 前置条件

- 已安装 Docker 和 Docker Compose
- 已安装并登录 Tailscale（`tailscale status` 正常）

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
- 若 `.env` 不存在：从 `.env.example` 复制并写入 `TS_IP`
- 若 `.env` 已存在：仅更新 `TS_IP`，其他自定义值（如 `TZ`）保持不变
- 启动所有容器（`docker compose up -d`）
- 等待 3 秒后自动验证端口监听，并打印将该节点加入 `servers.txt` 的具体命令

**（可选）自定义时区**

默认时区为 `Asia/Shanghai`。如需修改，在运行 `setup.sh` 之前手动创建 `.env`：

```bash
cp .env.example .env
vim .env   # 修改 TZ
```

这样 `setup.sh` 发现 `.env` 已存在，只会更新 `TS_IP`，`TZ` 不会被覆盖。

**3. 验证**

setup.sh 启动后会自动打印端口监听结果。如需手动验证：

```bash
# 确认监听在 Tailscale IP（不应出现 0.0.0.0）
ss -lntp | grep -E '9100|9115|8080'

# 验证指标可访问
curl -s "http://$(tailscale ip -4 | head -n1):9100/metrics" | head
curl -s "http://$(tailscale ip -4 | head -n1):9115/probe?target=https://www.baidu.com&module=http_2xx" | grep probe_success
```

期望结果：`probe_success 1`

---

## 二、部署中心监控机（monitoring）

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
```

`.env` 中各变量说明：

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `TZ` | 所有容器的时区 | `Asia/Shanghai` |
| `GF_ADMIN_USER` | Grafana 管理员用户名 | `admin` |
| `GF_ADMIN_PASSWORD` | Grafana 管理员密码（**务必修改**） | 无 |
| `DOMAIN` | Grafana 公开访问域名 | 无 |
| `PROMETHEUS_RETENTION` | Prometheus 数据保留时长 | `30d` |

后续再次运行 `setup.sh` 会直接加载已有 `.env`，不再提示。

脚本还会依次执行：
- 创建运行时数据目录（`data/prometheus`、`data/alertmanager`、`grafana/data`）
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

```bash
docker compose up -d
docker compose ps
```

**6. 配置 Nginx**

参考 `nginx/monitor.conf` 示例，将 `monitor.example.com` 替换为实际域名后部署：

```bash
cp nginx/monitor.conf /etc/nginx/conf.d/monitor.conf
vim /etc/nginx/conf.d/monitor.conf   # 替换域名和证书路径
```

在 `/etc/nginx/nginx.conf` 的 `http {}` 块中加入（Grafana Live WebSocket 支持）：

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
```

```bash
nginx -t && systemctl reload nginx
```

**7. 验证**

```bash
# 检查 Prometheus 配置语法
docker exec prometheus promtool check config /etc/prometheus/prometheus.yml

# 确认端口只监听 127.0.0.1
ss -lntp | grep -E '9090|9093|3000'
```

访问 Grafana：`https://<DOMAIN>`，使用配置时填写的账号密码登录。

---

## 三、新增服务器

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

## 四、删除服务器

```bash
cd ~/y-monitor/monitoring
vim servers.txt   # 删除对应行
./gen-targets.sh
```

---

## 五、防火墙配置

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

不要开放 `9100`、`9115`、`8080`。

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

不要开放 `9090`、`9093`、`3000`。

---

## 六、常用维护命令

```bash
# 查看容器状态
docker compose ps

# 查看日志
docker logs -f prometheus
docker logs -f grafana
docker logs -f alertmanager

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

## 七、告警配置

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

## 八、数据保留配置

Prometheus 默认将采集到的时序数据存储在 `monitoring/data/prometheus/` 目录，保留时长由 `.env` 中的 `PROMETHEUS_RETENTION` 控制，最终传递给容器启动参数 `--storage.tsdb.retention.time`。

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
```

### 注意事项

- 缩短保留时长（如从 `90d` 改为 `30d`）并重启后，Prometheus 会在后台逐步清理过期数据块，**不会立即释放磁盘空间**，通常在数小时到一天内完成。
- 如果磁盘空间紧张需要立即释放，可以停止容器后手动删除 `data/prometheus/` 下的旧数据块目录（文件名为 26 位 ULID 格式），但会丢失对应时段的历史数据。
- Prometheus 没有按指标类型单独设置保留时长的选项，所有 job 的数据共用同一个保留策略。

---

## 九、数据备份与迁移

```bash
cd ~
tar -czf monitoring-backup.tar.gz y-monitor/monitoring/data y-monitor/monitoring/grafana/data
```

迁移到新机器：

```bash
scp monitoring-backup.tar.gz root@新机器IP:/root/
ssh root@新机器IP
cd /root && tar -xzf monitoring-backup.tar.gz
cd y-monitor/monitoring && docker compose up -d
```

> Prometheus 30 天 TSDB 通常占几 GB 到几十 GB。若无需保留历史指标，可只备份配置文件（`servers.txt`、`probes/`、`prometheus/`、`alertmanager/`、`grafana/dashboards/`、`.env`），跳过 `data/` 和 `grafana/data/`。
