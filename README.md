# simple-proxy-2-docker

面向多台 VPS 的一键代理节点部署脚本，适合在已经运行 1Panel / OpenResty 的服务器上追加代理能力。

本项目会自动部署：

- Xray：VLESS + REALITY + XHTTP
- Hysteria 2：UDP 端口跳跃
- Cloudflare DNS：自动创建 / 更新 A 与 AAAA 记录
- acme.sh：通过 Cloudflare DNS-01 自动签发证书
- Docker Compose：统一容器化运行

设计目标很简单：不占用 `80/tcp` 和 `443/tcp`，尽量不影响 1Panel 原有网站。

---

## 特性

- 一键部署 VLESS + REALITY + XHTTP 与 Hysteria 2
- 自动探测服务器公网 IPv4 / IPv6
- 自动识别 Cloudflare Zone 并写入 DNS only 灰云记录
- 支持 Hysteria 2 UDP port hopping，默认 `40000-50000/udp`
- REALITY SNI / target 可固定，也可从候选池随机选择并持久化
- 自动生成客户端连接信息与 Hysteria 2 客户端 YAML
- 支持 `cleanup / uninstall / purge` 一键彻底清理节点
- 使用 host network，降低 Docker IPv6 与 UDP 转发复杂度

---

## 架构

```text
Cloudflare DNS
├─ A    -> VPS IPv4, DNS only
└─ AAAA -> VPS IPv6, DNS only

VPS
├─ 1Panel / OpenResty
│  ├─ 80/tcp
│  └─ 443/tcp
│
├─ Xray
│  └─ 24443/tcp
│     └─ VLESS + REALITY + XHTTP
│
└─ Hysteria 2
   └─ 40000-50000/udp
      └─ UDP port hopping
```

---

## 模块与版本

| 模块 | 当前项目使用方式 | 默认版本 / 标签 | 说明 |
|---|---|---|---|
| 安装脚本 | `install-proxy-stack.sh` | v2 | 项目内置自动化脚本 |
| Xray Core | Docker 镜像 | `ghcr.io/xtls/xray-core:latest` | 用于 VLESS + REALITY + XHTTP |
| Hysteria 2 | Docker 镜像 | `tobyxdd/hysteria:latest` | 用于 Hysteria 2 服务端与端口跳跃 |
| Docker | 宿主机提供 | 未固定 | 建议使用 Docker Engine 24+ |
| Docker Compose | 宿主机插件 | 未固定 | 需要支持 `docker compose`，建议 Compose v2+ |
| acme.sh | 在线安装 | latest | 用于 DNS-01 证书签发与续期 |
| Cloudflare API | HTTPS API | v4 | 用于 Token 校验、Zone 查询、DNS 记录写入 |
| Python | 宿主机提供 | Python 3 | 用于参数校验、JSON 处理、IP 校验 |

> 生产环境最佳实践：当前脚本默认拉取 `latest` 镜像，部署方便但版本不锁定。如果你追求长期稳定，建议在脚本里的镜像标签改成明确版本号后再上线。

---

## 前置要求

推荐系统：

- Debian 11+
- Ubuntu 20.04+

服务器需要具备：

- root 权限
- Docker
- Docker Compose Plugin
- `curl`
- `openssl`
- `python3`
- `ca-certificates`

如果服务器还没有 Docker，可以先安装：

```bash
curl -fsSL https://get.docker.com | bash
systemctl enable docker
systemctl start docker
docker compose version
```

---

## Cloudflare Token

进入 Cloudflare 后台创建 API Token：

```text
My Profile
-> API Tokens
-> Create Token
-> Custom token
```

推荐权限：

| 权限 | 用途 |
|---|---|
| `Zone - Zone - Read` | 自动识别域名所在 Zone |
| `Zone - DNS - Edit` | 创建 / 更新 / 删除 A 与 AAAA 记录 |

推荐 Zone Resource：

```text
Include - Specific zone - example.com
```

建议每个根域名使用单独 Token，权限更清晰，后续撤销也更安全。

---

## 快速部署

以下示例假设节点域名为 `jp1.example.com`。

### 1. 创建全局配置

```bash
cat > /root/proxy-global.env <<'EOF'
EMAIL="you@example.com"
CF_TOKEN="your_cloudflare_api_token"

DEFAULT_XRAY_PORT="24443"
DEFAULT_HY2_PORT_RANGE="40000-50000"

ENABLE_IPV6="true"

REALITY_SNI_POOL="www.oracle.com,www.ibm.com,www.samsung.com,www.lg.com,developer.mozilla.org,source.android.com,www.intel.com,www.amd.com,www.lenovo.com,www.dell.com"
EOF

chmod 600 /root/proxy-global.env
```

### 2. 下载脚本

请使用 GitHub raw 地址下载脚本：

```bash
curl -fsSL -o /root/install-proxy-stack.sh \
  https://raw.githubusercontent.com/feng005211/simple-proxy-2-docker/main/install-proxy-stack.sh

chmod +x /root/install-proxy-stack.sh
```

### 3. 放行端口

云厂商安全组需要放行：

```text
24443/tcp
40000-50000/udp
```

如果使用 `ufw`：

```bash
ufw allow 24443/tcp
ufw allow 40000:50000/udp
ufw status
```

### 4. 执行部署

```bash
bash /root/install-proxy-stack.sh jp1.example.com
```

等同于：

```bash
bash /root/install-proxy-stack.sh jp1.example.com 24443 40000-50000
```

自定义端口：

```bash
bash /root/install-proxy-stack.sh jp1.example.com 25443 41000-50000
```

---

## 部署产物

以 `jp1.example.com` 为例，默认安装目录为：

```text
/opt/proxy-stack-jp1-example-com
```

主要文件：

| 路径 | 说明 |
|---|---|
| `docker-compose.yml` | Xray 与 Hysteria 2 容器定义 |
| `xray/config.json` | Xray 服务端配置 |
| `hysteria/config.yaml` | Hysteria 2 服务端配置 |
| `certs/fullchain.pem` | acme.sh 安装的证书链 |
| `certs/privkey.pem` | acme.sh 安装的私钥 |
| `secrets.env` | UUID、REALITY 密钥、Hysteria 密码等敏感参数 |
| `client-info.txt` | 客户端连接信息汇总 |
| `clients/hysteria2-client.yaml` | Hysteria 2 客户端配置 |

查看客户端信息：

```bash
cat /opt/proxy-stack-jp1-example-com/client-info.txt
```

---

## 参数说明

### 命令行参数

```bash
bash install-proxy-stack.sh <domain> [xray_tcp_port] [hysteria_udp_range]
bash install-proxy-stack.sh cleanup <domain>
bash install-proxy-stack.sh uninstall <domain>
bash install-proxy-stack.sh purge <domain>
```

| 参数 | 必填 | 默认值 | 说明 |
|---|---:|---|---|
| `domain` | 是 | 无 | 节点域名，例如 `jp1.example.com` |
| `xray_tcp_port` | 否 | `24443` | Xray VLESS + REALITY + XHTTP 监听端口 |
| `hysteria_udp_range` | 否 | `40000-50000` | Hysteria 2 UDP 端口跳跃范围 |

### 环境变量

环境变量可以写入 `/root/proxy-global.env`。

| 变量 | 必填 | 默认值 | 说明 |
|---|---:|---|---|
| `EMAIL` | 是 | 无 | acme.sh 注册与证书申请邮箱 |
| `CF_TOKEN` | 是 | 无 | Cloudflare API Token |
| `DEFAULT_XRAY_PORT` | 否 | `24443` | 默认 Xray TCP 端口 |
| `DEFAULT_HY2_PORT_RANGE` | 否 | `40000-50000` | 默认 Hysteria 2 UDP 范围 |
| `ENABLE_IPV6` | 否 | `true` | 为 `true` 时自动探测 IPv6 并写入 AAAA |
| `PUBLIC_IPV4` | 否 | 自动探测 | 手动指定公网 IPv4 |
| `PUBLIC_IPV6` | 否 | 自动探测 | 手动指定公网 IPv6 |
| `PUBLIC_IP` | 否 | 空 | 兼容旧变量，等价于 IPv4 覆盖 |
| `INSTALL_DIR` | 否 | `/opt/proxy-stack-<domain>` | 自定义安装目录 |
| `MASQUERADE_URL` | 否 | `https://<domain>/` | Hysteria 2 masquerade 代理地址 |
| `REALITY_SNI` | 否 | 随机选择 | 固定 REALITY serverName |
| `REALITY_TARGET` | 否 | `<REALITY_SNI>:443` | 固定 REALITY 回落目标 |
| `REALITY_SNI_POOL` | 否 | 内置候选池 | 未指定 `REALITY_SNI` 时随机选择 |

固定 REALITY 目标示例：

```bash
cat > /root/proxy-global.env <<'EOF'
EMAIL="you@example.com"
CF_TOKEN="your_cloudflare_api_token"

DEFAULT_XRAY_PORT="24443"
DEFAULT_HY2_PORT_RANGE="40000-50000"
ENABLE_IPV6="true"

REALITY_SNI="www.oracle.com"
REALITY_TARGET="www.oracle.com:443"
EOF

chmod 600 /root/proxy-global.env
```

---

## 日常运维

进入安装目录：

```bash
cd /opt/proxy-stack-jp1-example-com
```

查看状态：

```bash
docker compose ps
```

查看日志：

```bash
docker compose logs -f --tail=100
```

只看 Xray：

```bash
docker compose logs -f --tail=100 xray
```

只看 Hysteria 2：

```bash
docker compose logs -f --tail=100 hysteria
```

升级镜像并重启：

```bash
docker compose pull
docker compose up -d
```

重启服务：

```bash
docker compose restart
```

---

## 一键清理

清理某个节点：

```bash
bash /root/install-proxy-stack.sh cleanup jp1.example.com
```

等价命令：

```bash
bash /root/install-proxy-stack.sh uninstall jp1.example.com
bash /root/install-proxy-stack.sh purge jp1.example.com
```

清理会执行：

- 停止并删除 Docker Compose 服务
- 删除默认安装目录 `/opt/proxy-stack-*`
- 删除 Cloudflare 中该域名的 A / AAAA 记录
- 删除 acme.sh 中该域名的 ECC 证书目录

注意：如果没有提供 `CF_TOKEN`，脚本会跳过 Cloudflare DNS 清理。

---

## 最佳实践

- 不要把根域名直接作为代理节点，推荐使用 `jp1.example.com`、`sg1.example.com`、`us1.example.com` 这类子域名。
- Cloudflare 记录必须保持 DNS only 灰云；普通橙云代理不适合直接代理这些端口。
- 不要多台 VPS 共用同一个节点域名，否则 DNS 会被最后一次部署覆盖。
- 云厂商安全组和系统防火墙都要放行 TCP 与 UDP 端口，IPv6 入站规则也要单独确认。
- 妥善保管 `secrets.env`、`client-info.txt` 和客户端 YAML，它们包含可直接连接的敏感信息。
- 生产环境建议锁定 Docker 镜像版本，不长期依赖 `latest`。
- 重新运行安装脚本会复用已有 `secrets.env`，不会随便更换 UUID、REALITY 密钥和 Hysteria 密码。
- 只有确认要让旧客户端全部失效时，才执行 `cleanup` 后重新部署。
- Cloudflare Token 建议只授权目标 Zone，不要使用全账号全域名权限。
- 证书使用 DNS-01 签发，不占用 `80/tcp` 和 `443/tcp`，适合与 1Panel / OpenResty 共存。

---

## 故障排查

### Docker Compose 不存在

```bash
docker compose version
```

如果命令不可用，请先安装 Docker Compose Plugin。

### Cloudflare DNS 写入失败

检查：

- `CF_TOKEN` 是否正确
- Token 是否包含 `Zone Read` 与 `DNS Edit`
- Token 是否授权了当前根域名
- 节点域名是否托管在 Cloudflare
- 同名是否存在 CNAME 记录

### IPv6 不通

检查服务器是否具备 IPv6：

```bash
ip -6 addr
curl -6 https://api64.ipify.org
```

如果服务器没有可用 IPv6，脚本会跳过 AAAA 记录，不影响 IPv4 部署。

### Hysteria 2 只看到一个 UDP 端口

这是端口跳跃的常见表现。Hysteria 2 通常只直接监听范围内的起始端口，其余端口可能通过 nftables / iptables 规则处理。

### 客户端无法连接 VLESS

请对照 `client-info.txt` 检查：

- `address`
- `port`
- `uuid`
- `network = xhttp`
- `path`
- `security = reality`
- `sni / serverName`
- `publicKey`
- `shortId`
- `fingerprint = chrome`
- `flow` 留空

---

## 项目文件

| 文件 | 说明 |
|---|---|
| `install-proxy-stack.sh` | 一键安装 / 清理脚本 |
| `deploy.md` | 更详细的中文部署说明 |
| `.gitattributes` | 固定 shell 脚本与 Markdown 使用 LF 行尾 |

---

## 免责声明

本项目仅用于个人服务器运维、网络连通性测试与自有设备访问场景。请遵守所在地法律法规、云厂商服务条款和网络服务使用规则。
