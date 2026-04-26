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

**2. （可选）修改时区**

默认时区为 `Asia/Shanghai`，如需修改：

```bash
cd ~/monitor-agent
cp .env.example .env
vim .env   # 修改 TZ
```

**3. 运行部署脚本**

```bash
cd ~/monitor-agent
bash setup.sh
```

脚本会自动读取 Tailscale IP 写入 `.env` 并启动所有容器。如果 `.env` 已存在，只更新 `TS_IP`，`TZ` 等自定义值保持不变。

**4. 验证**

```bash
# 查看容器状态
docker compose ps

# 确认监听在 Tailscale IP（不应出现 0.0.0.0）
ss -lntp | grep -E '9100|9115|8080'

# 验证指标可访问
curl http://$(tailscale ip -4 | head -n1):9100/metrics | head
curl "http://$(tailscale ip -4 | head -n1):9115/probe?target=https://www.baidu.com&module=http_2xx" | grep probe_success
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

脚本还会：
- 修复 Grafana 数据目录权限
- 生成 Prometheus target 文件

**3. 添加被监控节点**

编辑 `servers.txt`：

```text
# TailscaleIP      node_name   region   cadvisor
100.85.140.54      jp-01       jp       yes
100.100.100.11     hk-01       hk       yes
```

字段说明：

| 字段 | 说明 |
|------|------|
| TailscaleIP | 被监控服务器的 Tailscale IPv4（`tailscale ip -4`） |
| node_name | 节点名，用于 Grafana 展示和告警 |
| region | 区域标签，如 `jp` `hk` `us` `sg` `cn` |
| cadvisor | 是否采集 Docker 容器指标，`yes` 或 `no` |

**4. 配置网络探测目标（可选）**

编辑 `probes/http_targets.txt`，添加要探测的 HTTP 地址：

```text
https://blog.example.com    self
https://s3.example.com      self
```

方向标签：`cn`（国内）、`global`（国际）、`self`（自有服务）

同理可编辑 `probes/icmp_targets.txt` 和 `probes/tcp_targets.txt`，修改后执行 `./gen-targets.sh` 重新生成。

**5. 配置 Nginx**

参考 `nginx/monitor.conf` 示例，将 `monitor.example.com` 替换为实际域名后，手动部署到 Nginx：

```bash
# 按实际域名修改后复制
cp nginx/monitor.conf /etc/nginx/conf.d/monitor.conf
vim /etc/nginx/conf.d/monitor.conf
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

**6. 启动服务**

```bash
docker compose up -d
docker compose ps
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

## 八、数据备份

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
