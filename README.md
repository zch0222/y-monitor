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
│   ├── docker-compose.yml
│   ├── setup.sh
│   └── blackbox/
│       └── blackbox.yml
└── monitoring/                 # 部署到中心监控机
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
    │   └── provisioning/datasources/datasource.yml
    ├── alertmanager/
    │   └── alertmanager.yml
    └── nginx/
        └── monitor.conf
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

**2. 在服务器上运行部署脚本**

```bash
cd ~/monitor-agent
bash setup.sh
```

脚本会自动读取 Tailscale IP 写入 `.env`，并启动所有容器。

**3. 验证**

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

**2. 修改配置**

编辑 `docker-compose.yml`，将 Grafana 域名改为实际域名：

```yaml
- GF_SERVER_ROOT_URL=https://monitor.example.com  # 改为你的域名
- GF_SECURITY_ADMIN_PASSWORD=ChangeMe_123456       # 改为强密码
```

编辑 `nginx/monitor.conf`，替换域名和证书路径：

```nginx
server_name monitor.example.com;               # 改为你的域名
ssl_certificate /etc/letsencrypt/live/monitor.example.com/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/monitor.example.com/privkey.pem;
```

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

同理可编辑 `probes/icmp_targets.txt` 和 `probes/tcp_targets.txt`。

**5. 运行初始化脚本**

```bash
bash setup.sh
```

脚本会修复 Grafana 目录权限并生成 Prometheus target 文件。

**6. 启动服务**

```bash
docker compose up -d
docker compose ps
```

**7. 配置 Nginx 并申请证书**

```bash
# 申请证书（以 certbot 为例）
certbot --nginx -d monitor.example.com

# 复制 nginx 配置
cp nginx/monitor.conf /etc/nginx/conf.d/monitor.conf
nginx -t && systemctl reload nginx
```

**8. 验证**

```bash
# 检查 Prometheus 配置语法
docker exec prometheus promtool check config /etc/prometheus/prometheus.yml

# 确认端口只监听 127.0.0.1
ss -lntp | grep -E '9090|9093|3000'
```

访问 Grafana：`https://monitor.example.com`，默认账号 `admin`，密码为步骤 2 中设置的值。

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

# 热重载 Prometheus
curl -X POST http://127.0.0.1:9090/-/reload

# 重置 Grafana admin 密码
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
| BlackboxHighLatency | 探测延迟 > 2 秒持续 5 分钟 |
| SSLCertExpiringSoon | SSL 证书 7 天内到期 |

如需接入 Telegram、企业微信、邮件等通知，编辑 `alertmanager/alertmanager.yml` 的 `receivers` 部分，然后重启 Alertmanager：

```bash
docker compose restart alertmanager
```

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
