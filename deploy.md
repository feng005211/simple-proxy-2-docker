# 1Panel 共存环境下自动化部署 VLESS + REALITY + XHTTP 与 Hysteria 2

本文档用于在多台 VPS 上自动化部署：

- Xray：VLESS + REALITY + XHTTP
- Hysteria 2：UDP 端口跳跃
- Cloudflare：自动 DNS 解析
- acme.sh：自动 DNS-01 证书签发与续期
- Docker Compose：统一容器化部署
- 1Panel / OpenResty：继续保持原有网站能力，不占用 80/443

---

## 一、最终目标

部署完成后，每台 VPS 会自动拥有：

| 服务 | 协议 | 默认端口 | 说明 |
|---|---:|---:|---|
| 1Panel / OpenResty | TCP | 80 / 443 | 保持原样，不修改 |
| Xray VLESS + REALITY + XHTTP | TCP | 24443 | 独立监听 |
| Hysteria 2 | UDP | 40000-50000 | 端口跳跃 |
| Cloudflare DNS | A / AAAA | 自动更新 | 支持 IPv4 / IPv6 |
| 证书 | DNS-01 | 自动签发 | 不占用 80/443 |

---

## 二、推荐域名规划

建议主站和代理节点分开：

~~~text
aa.com          主站，给 1Panel / OpenResty
www.aa.com      主站，给 1Panel / OpenResty

jp1.aa.com      日本 VPS 节点，DNS only
sg1.aa.com      新加坡 VPS 节点，DNS only
us1.aa.com      美国 VPS 节点，DNS only
hk1.aa.com      香港 VPS 节点，DNS only
~~~

不建议直接把 `aa.com` 用作代理节点，除非你确认主站也在这台 VPS 上，并且清楚 DNS 记录会被脚本改为灰云。

更推荐：

~~~text
主站：aa.com / www.aa.com
节点：jp1.aa.com / sg1.aa.com / us1.aa.com
~~~

---

## 三、Cloudflare API Token 准备

进入 Cloudflare 后台：

~~~text
My Profile
→ API Tokens
→ Create Token
→ Custom token
~~~

推荐权限：

~~~text
Zone - Zone - Read
Zone - DNS - Edit
~~~

Zone Resource 建议选择：

~~~text
Include - Specific zone - aa.com
~~~

如果你有多个根域名，例如：

~~~text
aa.com
bb.com
cc.net
~~~

有两种方式：

~~~text
方案 A：一个 Token 授权多个 Zone
方案 B：每个根域名单独一个 Token
~~~

更推荐方案 B，权限隔离更安全。

---

## 四、VPS 基础要求

系统建议：

~~~text
Debian 11+
Ubuntu 20.04+
~~~

需要已经安装：

~~~text
Docker
Docker Compose Plugin
curl
openssl
python3
~~~

如果你的 VPS 还没有 Docker，可以先安装：

~~~bash
curl -fsSL https://get.docker.com | bash
systemctl enable docker
systemctl start docker
~~~

检查 Docker Compose：

~~~bash
docker compose version
~~~

---

## 五、防火墙与安全组

你需要在 VPS 云厂商安全组里放行：

~~~text
24443/tcp
40000-50000/udp
~~~

如果你未来手动修改端口，也要同步改安全组。

如果系统使用 ufw，可以执行：

~~~bash
ufw allow 24443/tcp
ufw allow 40000:50000/udp
ufw status
~~~

如果你使用 IPv6，还需要确认云厂商的 IPv6 安全组也允许这些端口。

---

## 六、创建公共配置文件

在每台 VPS 上创建：

~~~bash
cat > /root/proxy-global.env <<'EOF'
EMAIL="你的邮箱@example.com"
CF_TOKEN="你的Cloudflare_API_Token"

DEFAULT_XRAY_PORT="24443"
DEFAULT_HY2_PORT_RANGE="40000-50000"

ENABLE_IPV6="true"

REALITY_SNI_POOL="www.oracle.com,www.ibm.com,www.samsung.com,www.lg.com,developer.mozilla.org,source.android.com,www.intel.com,www.amd.com,www.lenovo.com,www.dell.com"
EOF

chmod 600 /root/proxy-global.env
~~~

说明：

~~~text
EMAIL:
  用于 acme.sh 申请 Let's Encrypt 证书。

CF_TOKEN:
  Cloudflare API Token。

DEFAULT_XRAY_PORT:
  Xray 的 TCP 监听端口。

DEFAULT_HY2_PORT_RANGE:
  Hysteria 2 的 UDP 端口跳跃范围。

ENABLE_IPV6:
  true  表示自动探测 IPv6 并写入 AAAA 记录。
  false 表示只写入 IPv4 A 记录。

REALITY_SNI_POOL:
  REALITY SNI 候选池。
  如果不单独指定 REALITY_SNI，脚本会随机选择一个。
~~~

如果你想强制指定 REALITY 目标，可以改成：

~~~bash
cat > /root/proxy-global.env <<'EOF'
EMAIL="你的邮箱@example.com"
CF_TOKEN="你的Cloudflare_API_Token"

DEFAULT_XRAY_PORT="24443"
DEFAULT_HY2_PORT_RANGE="40000-50000"

ENABLE_IPV6="true"

REALITY_SNI="www.oracle.com"
REALITY_TARGET="www.oracle.com:443"
EOF

chmod 600 /root/proxy-global.env
~~~

---

## 七、完整自动化部署脚本

下载脚本：

~~~bash
wget -O /root/install-proxy-stack.sh --no-check-certificate \
  https://raw.githubusercontent.com/feng005211/simple-proxy-2-docker/main/install-proxy-stack.sh && \
chmod 700 /root/install-proxy-stack.sh
~~~

如果服务器没有 `wget`，也可以使用：

~~~bash
curl -fsSL -o /root/install-proxy-stack.sh \
  https://raw.githubusercontent.com/feng005211/simple-proxy-2-docker/main/install-proxy-stack.sh && \
chmod 700 /root/install-proxy-stack.sh
~~~

写入以下内容：

~~~bash
#!/usr/bin/env bash
set -euo pipefail

GLOBAL_ENV="/root/proxy-global.env"

if [ ! -f "$GLOBAL_ENV" ]; then
  echo "缺少配置文件: $GLOBAL_ENV"
  echo
  echo "请先创建 /root/proxy-global.env"
  exit 1
fi

source "$GLOBAL_ENV"

DOMAIN="${1:-}"
XRAY_PORT="${2:-${DEFAULT_XRAY_PORT:-24443}}"
HY2_PORT_RANGE="${3:-${DEFAULT_HY2_PORT_RANGE:-40000-50000}}"

if [ -z "$DOMAIN" ]; then
  echo "用法:"
  echo "  bash $0 <域名> [Xray端口] [Hysteria端口范围]"
  echo
  echo "示例:"
  echo "  bash $0 jp1.aa.com"
  echo "  bash $0 jp1.aa.com 24443 40000-50000"
  exit 1
fi

if ! [[ "$XRAY_PORT" =~ ^[0-9]+$ ]]; then
  echo "Xray 端口必须是数字: $XRAY_PORT"
  exit 1
fi

if ! [[ "$HY2_PORT_RANGE" =~ ^[0-9]+-[0-9]+$ ]]; then
  echo "Hysteria 端口范围格式错误，应类似: 40000-50000"
  exit 1
fi

HY2_PORT_START="${HY2_PORT_RANGE%-*}"
HY2_PORT_END="${HY2_PORT_RANGE#*-}"

if [ "$HY2_PORT_START" -gt "$HY2_PORT_END" ]; then
  echo "Hysteria 端口范围错误: 起始端口大于结束端口"
  exit 1
fi

SAFE_DOMAIN="${DOMAIN//./-}"
INSTALL_DIR="/opt/proxy-stack-${SAFE_DOMAIN}"

REALITY_SNI_POOL="${REALITY_SNI_POOL:-www.oracle.com,www.ibm.com,www.samsung.com,www.lg.com,developer.mozilla.org,source.android.com,www.intel.com,www.amd.com,www.lenovo.com,www.dell.com}"
ENABLE_IPV6="${ENABLE_IPV6:-true}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "缺少命令: $1"
    exit 1
  }
}

need_cmd docker
need_cmd curl
need_cmd openssl
need_cmd python3

docker compose version >/dev/null 2>&1 || {
  echo "缺少 docker compose 插件"
  echo "请确认 docker compose version 可正常执行"
  exit 1
}

mkdir -p "$INSTALL_DIR"/{xray,hysteria,certs,clients}

echo
echo "========================================"
echo " 自动化部署开始"
echo "========================================"
echo "域名: $DOMAIN"
echo "安装目录: $INSTALL_DIR"
echo "Xray TCP 端口: $XRAY_PORT"
echo "Hysteria UDP 跳跃范围: $HY2_PORT_RANGE"
echo "IPv6: $ENABLE_IPV6"
echo

echo "[1/9] 验证 Cloudflare Token..."

CF_API="https://api.cloudflare.com/client/v4"

curl -fsS \
  -H "Authorization: Bearer ${CF_TOKEN}" \
  "${CF_API}/user/tokens/verify" \
  >/dev/null

echo "Cloudflare Token 验证成功"

cf_get() {
  curl -fsS \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    -H "Content-Type: application/json" \
    "$1"
}

cf_send() {
  local method="$1"
  local url="$2"
  local data="$3"

  curl -fsS \
    -X "$method" \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$data" \
    "$url"
}

echo
echo "[2/9] 获取公网 IP..."

PUBLIC_IPV4=""
PUBLIC_IPV6=""

PUBLIC_IPV4="$(curl -4fsS --max-time 10 https://api.ipify.org || true)"

if [ "$ENABLE_IPV6" = "true" ]; then
  PUBLIC_IPV6="$(curl -6fsS --max-time 10 https://api64.ipify.org || true)"
fi

if [ -z "$PUBLIC_IPV4" ] && [ -z "$PUBLIC_IPV6" ]; then
  echo "无法获取公网 IPv4 或 IPv6"
  exit 1
fi

echo "IPv4: ${PUBLIC_IPV4:-未检测到}"
echo "IPv6: ${PUBLIC_IPV6:-未检测到}"

echo
echo "[3/9] 自动识别 Cloudflare Zone..."

ZONES_JSON="$(cf_get "${CF_API}/zones?per_page=50")"

ZONE_INFO="$(echo "$ZONES_JSON" | python3 - "$DOMAIN" <<'PY'
import sys, json

domain = sys.argv[1].rstrip(".")
data = json.load(sys.stdin)
zones = data.get("result", [])

matches = []
for z in zones:
    name = z.get("name", "").rstrip(".")
    zid = z.get("id", "")
    if domain == name or domain.endswith("." + name):
        matches.append((len(name), zid, name))

if not matches:
    print("")
else:
    matches.sort(reverse=True)
    print(matches[0][1] + "|" + matches[0][2])
PY
)"

if [ -z "$ZONE_INFO" ]; then
  echo "没有在 Cloudflare Token 权限内找到 ${DOMAIN} 对应的 Zone"
  echo "请确认 Token 至少有对应根域名的 Zone Read + DNS Edit 权限"
  exit 1
fi

ZONE_ID="${ZONE_INFO%%|*}"
ZONE_NAME="${ZONE_INFO#*|}"

echo "识别到 Zone: $ZONE_NAME"

upsert_dns_record() {
  local record_type="$1"
  local record_name="$2"
  local record_content="$3"

  if [ -z "$record_content" ]; then
    return 0
  fi

  local cname_id
  cname_id="$(cf_get "${CF_API}/zones/${ZONE_ID}/dns_records?type=CNAME&name=${record_name}" | python3 -c '
import sys,json
j=json.load(sys.stdin)
r=j.get("result",[])
print(r[0]["id"] if r else "")
')"

  if [ -n "$cname_id" ]; then
    echo "发现同名 CNAME 记录，无法同时创建 ${record_type}: ${record_name}"
    echo "请先在 Cloudflare 删除该 CNAME，或换一个子域名"
    exit 1
  fi

  local record_id
  record_id="$(cf_get "${CF_API}/zones/${ZONE_ID}/dns_records?type=${record_type}&name=${record_name}" | python3 -c '
import sys,json
j=json.load(sys.stdin)
r=j.get("result",[])
print(r[0]["id"] if r else "")
')"

  local payload
  payload="$(python3 - "$record_type" "$record_name" "$record_content" <<'PY'
import sys,json
rtype, name, content = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({
  "type": rtype,
  "name": name,
  "content": content,
  "ttl": 120,
  "proxied": False
}))
PY
)"

  if [ -z "$record_id" ]; then
    cf_send POST "${CF_API}/zones/${ZONE_ID}/dns_records" "$payload" >/dev/null
    echo "已创建 ${record_type} 记录: ${record_name} -> ${record_content}，DNS only"
  else
    cf_send PUT "${CF_API}/zones/${ZONE_ID}/dns_records/${record_id}" "$payload" >/dev/null
    echo "已更新 ${record_type} 记录: ${record_name} -> ${record_content}，DNS only"
  fi
}

echo
echo "[4/9] 创建/更新 Cloudflare DNS 记录..."

if [ -n "$PUBLIC_IPV4" ]; then
  upsert_dns_record "A" "$DOMAIN" "$PUBLIC_IPV4"
else
  echo "未检测到 IPv4，跳过 A 记录"
fi

if [ "$ENABLE_IPV6" = "true" ] && [ -n "$PUBLIC_IPV6" ]; then
  upsert_dns_record "AAAA" "$DOMAIN" "$PUBLIC_IPV6"
else
  echo "未启用 IPv6 或未检测到 IPv6，跳过 AAAA 记录"
fi

echo
echo "[5/9] 生成或复用密钥..."

SECRETS_FILE="${INSTALL_DIR}/secrets.env"

pick_random_sni() {
  python3 - "$REALITY_SNI_POOL" <<'PY'
import random, re, sys
pool = [x.strip() for x in re.split(r'[, \t\r\n]+', sys.argv[1]) if x.strip()]
if not pool:
    print("www.oracle.com")
else:
    print(random.choice(pool))
PY
}

if [ ! -f "$SECRETS_FILE" ]; then
  XRAY_UUID="$(docker run --rm ghcr.io/xtls/xray-core:latest uuid)"

  XRAY_KEYS="$(docker run --rm ghcr.io/xtls/xray-core:latest x25519)"
  REALITY_PRIVATE_KEY="$(echo "$XRAY_KEYS" | awk '/Private key:/ {print $3}')"
  REALITY_PUBLIC_KEY="$(echo "$XRAY_KEYS" | awk '/Public key:/ {print $3}')"

  SHORT_ID="$(openssl rand -hex 8)"
  XHTTP_PATH="/$(openssl rand -hex 10)"

  HY2_PASSWORD="$(openssl rand -hex 24)"
  HY2_OBFS_PASSWORD="$(openssl rand -hex 24)"

  SELECTED_REALITY_SNI="${REALITY_SNI:-$(pick_random_sni)}"
  SELECTED_REALITY_TARGET="${REALITY_TARGET:-${SELECTED_REALITY_SNI}:443}"

  cat > "$SECRETS_FILE" <<SECRETS
XRAY_UUID="${XRAY_UUID}"
REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY}"
REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY}"
SHORT_ID="${SHORT_ID}"
XHTTP_PATH="${XHTTP_PATH}"
HY2_PASSWORD="${HY2_PASSWORD}"
HY2_OBFS_PASSWORD="${HY2_OBFS_PASSWORD}"
SELECTED_REALITY_SNI="${SELECTED_REALITY_SNI}"
SELECTED_REALITY_TARGET="${SELECTED_REALITY_TARGET}"
SECRETS

  chmod 600 "$SECRETS_FILE"
  echo "已生成新密钥"
else
  echo "检测到已有 secrets.env，复用旧密钥，避免客户端失效"
fi

source "$SECRETS_FILE"

echo "REALITY SNI: ${SELECTED_REALITY_SNI}"
echo "REALITY Target: ${SELECTED_REALITY_TARGET}"

echo
echo "[6/9] 安装 / 签发证书..."

if [ ! -x "$HOME/.acme.sh/acme.sh" ]; then
  curl https://get.acme.sh | sh -s email="$EMAIL"
fi

export CF_Token="$CF_TOKEN"

"$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt

if [ ! -f "${INSTALL_DIR}/certs/fullchain.pem" ] || [ ! -f "${INSTALL_DIR}/certs/privkey.pem" ]; then
  "$HOME/.acme.sh/acme.sh" --issue \
    --dns dns_cf \
    -d "$DOMAIN" \
    --keylength ec-256
else
  echo "检测到已有证书文件，跳过首次签发"
fi

"$HOME/.acme.sh/acme.sh" --install-cert \
  -d "$DOMAIN" \
  --ecc \
  --fullchain-file "${INSTALL_DIR}/certs/fullchain.pem" \
  --key-file "${INSTALL_DIR}/certs/privkey.pem" \
  --reloadcmd "cd ${INSTALL_DIR} && docker compose restart hysteria >/dev/null 2>&1 || true"

chmod 600 "${INSTALL_DIR}/certs/privkey.pem"

echo
echo "[7/9] 写入 Docker Compose 与服务配置..."

cat > "${INSTALL_DIR}/docker-compose.yml" <<COMPOSE
services:
  xray:
    image: ghcr.io/xtls/xray-core:latest
    container_name: xray-${SAFE_DOMAIN}
    restart: unless-stopped
    network_mode: "host"
    volumes:
      - ./xray/config.json:/etc/xray/config.json:ro
    command: ["run", "-config", "/etc/xray/config.json"]

  hysteria:
    image: tobyxdd/hysteria:latest
    container_name: hysteria2-${SAFE_DOMAIN}
    restart: unless-stopped
    network_mode: "host"
    cap_add:
      - NET_ADMIN
    volumes:
      - ./hysteria/config.yaml:/etc/hysteria.yaml:ro
      - ./certs:/certs:ro
    command: ["server", "-c", "/etc/hysteria.yaml"]
COMPOSE

cat > "${INSTALL_DIR}/xray/config.json" <<XRAY
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality-xhttp",
      "listen": "::",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${XRAY_UUID}",
            "email": "main-user"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {
          "path": "${XHTTP_PATH}",
          "mode": "auto"
        },
        "realitySettings": {
          "show": false,
          "target": "${SELECTED_REALITY_TARGET}",
          "serverNames": [
            "${SELECTED_REALITY_SNI}"
          ],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
XRAY

MASQUERADE_URL="${MASQUERADE_URL:-https://${DOMAIN}/}"

cat > "${INSTALL_DIR}/hysteria/config.yaml" <<HY2
listen: :${HY2_PORT_RANGE}

tls:
  cert: /certs/fullchain.pem
  key: /certs/privkey.pem
  sniGuard: strict

auth:
  type: password
  password: ${HY2_PASSWORD}

obfs:
  type: salamander
  salamander:
    password: ${HY2_OBFS_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: ${MASQUERADE_URL}
    rewriteHost: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 41943040
  maxIdleTimeout: 60s
  maxIncomingStreams: 1024

bandwidth:
  up: 1 gbps
  down: 1 gbps
HY2

cat > "${INSTALL_DIR}/clients/hysteria2-client.yaml" <<HY2CLIENT
server: ${DOMAIN}:${HY2_PORT_RANGE}

auth: ${HY2_PASSWORD}

tls:
  sni: ${DOMAIN}
  insecure: false

obfs:
  type: salamander
  salamander:
    password: ${HY2_OBFS_PASSWORD}

transport:
  udp:
    minHopInterval: 15s
    maxHopInterval: 45s

bandwidth:
  up: 1 gbps
  down: 1 gbps
HY2CLIENT

cat > "${INSTALL_DIR}/client-info.txt" <<INFO
========== 节点信息 ==========

domain: ${DOMAIN}
install dir: ${INSTALL_DIR}
IPv4: ${PUBLIC_IPV4:-未检测到}
IPv6: ${PUBLIC_IPV6:-未检测到}

========== VLESS + REALITY + XHTTP ==========

address: ${DOMAIN}
port: ${XRAY_PORT}
uuid: ${XRAY_UUID}
network: xhttp
xhttp path: ${XHTTP_PATH}
security: reality
sni/serverName: ${SELECTED_REALITY_SNI}
publicKey/password: ${REALITY_PUBLIC_KEY}
shortId: ${SHORT_ID}
fingerprint: chrome
flow: 留空

========== Hysteria 2 ==========

server: ${DOMAIN}:${HY2_PORT_RANGE}
auth: ${HY2_PASSWORD}
tls sni: ${DOMAIN}
obfs type: salamander
obfs password: ${HY2_OBFS_PASSWORD}
hysteria2 official uri:
hysteria2://your_auth@${DOMAIN}:40000-50000/?sni=${DOMAIN}&insecure=0&obfs=salamander&obfs-password=your_obfs_password#${DOMAIN}-hysteria2
hysteria2 official yaml:
${INSTALL_DIR}/clients/hysteria2-client.yaml
sing-box json:
${INSTALL_DIR}/sing-box-client-info.json
clash / mihomo yaml:
${INSTALL_DIR}/clash-client-info.txt

transport:
  udp:
    minHopInterval: 15s
    maxHopInterval: 45s

========== 文件位置 ==========

docker compose:
  ${INSTALL_DIR}/docker-compose.yml

Xray config:
  ${INSTALL_DIR}/xray/config.json

Hysteria server config:
  ${INSTALL_DIR}/hysteria/config.yaml

Hysteria client config:
  ${INSTALL_DIR}/clients/hysteria2-client.yaml

secrets:
  ${INSTALL_DIR}/secrets.env
INFO

chmod 600 "${INSTALL_DIR}/client-info.txt"
chmod 600 "${INSTALL_DIR}/clients/hysteria2-client.yaml"

echo
echo "[8/9] 启动 Docker 服务..."

cd "$INSTALL_DIR"
docker compose pull
docker compose up -d

echo
echo "[9/9] 检查监听状态..."

sleep 2

docker compose ps || true

echo
echo "TCP 监听检查:"
ss -lntup | grep ":${XRAY_PORT}" || true

echo
echo "UDP 监听检查:"
ss -lnuup | grep ":${HY2_PORT_START}" || true

echo
echo "========================================"
echo " 部署完成"
echo "========================================"
echo
echo "客户端信息:"
echo "${INSTALL_DIR}/client-info.txt"
echo
cat "${INSTALL_DIR}/client-info.txt"
echo
echo "Hysteria 2 客户端配置:"
echo "${INSTALL_DIR}/clients/hysteria2-client.yaml"
echo
~~~

验证脚本：

~~~bash
bash /root/install-proxy-stack.sh --help
~~~

---

## 八、一键部署

例如部署日本节点：

~~~bash
bash /root/install-proxy-stack.sh jp1.aa.com
~~~

等同于：

~~~bash
bash /root/install-proxy-stack.sh jp1.aa.com 24443 40000-50000
~~~

如果想自定义端口：

~~~bash
bash /root/install-proxy-stack.sh jp1.aa.com 25443 41000-50000
~~~

如果想使用 Hysteria 2 单端口模式：

~~~bash
bash /root/install-proxy-stack.sh hk1.aa.com 24443 10001
~~~

如果想调用 BBR、DD 附加工具入口：

~~~bash
bash /root/install-proxy-stack.sh bbr
bash /root/install-proxy-stack.sh dd
~~~

说明：

~~~text
bbr 入口会运行 Linux-NetSpeed 的 tcpx.sh
dd 入口会运行 Linux-NetSpeed 的 tcp.sh
这里的 dd 入口对应替换内核版脚本，不是系统重装 DD 工具
BBR、DD 脚本用的 [ylx2016] 的成熟作品，地址 [https://github.com/ylx2016/Linux-NetSpeed]，请熟知
~~~

如果想一键彻底清理某个节点：

~~~bash
bash /root/install-proxy-stack.sh cleanup jp1.aa.com
~~~

也兼容下面两个别名：

~~~bash
bash /root/install-proxy-stack.sh uninstall jp1.aa.com
bash /root/install-proxy-stack.sh purge jp1.aa.com
~~~

---

## 九、部署完成后的文件位置

假设域名是：

~~~text
jp1.aa.com
~~~

安装目录会是：

~~~text
/opt/proxy-stack-jp1-aa-com
~~~

主要文件：

~~~text
/opt/proxy-stack-jp1-aa-com/docker-compose.yml
/opt/proxy-stack-jp1-aa-com/xray/config.json
/opt/proxy-stack-jp1-aa-com/hysteria/config.yaml
/opt/proxy-stack-jp1-aa-com/certs/fullchain.pem
/opt/proxy-stack-jp1-aa-com/certs/privkey.pem
/opt/proxy-stack-jp1-aa-com/secrets.env
/opt/proxy-stack-jp1-aa-com/client-info.txt
/opt/proxy-stack-jp1-aa-com/clients/hysteria2-client.yaml
~~~

查看客户端参数：

~~~bash
cat /opt/proxy-stack-jp1-aa-com/client-info.txt
~~~

查看 Hysteria 2 客户端配置：

~~~bash
cat /opt/proxy-stack-jp1-aa-com/clients/hysteria2-client.yaml
~~~

---

## 十、客户端配置说明

### 1. VLESS + REALITY + XHTTP

客户端参数来自：

~~~bash
cat /opt/proxy-stack-jp1-aa-com/client-info.txt
~~~

需要填写：

~~~text
address: jp1.aa.com
port: 24443
uuid: 脚本生成
network: xhttp
xhttp path: 脚本生成
security: reality
sni/serverName: 脚本随机选择
publicKey/password: 脚本生成
shortId: 脚本生成
fingerprint: chrome
flow: 留空
~~~

注意：

~~~text
客户端连接地址是你的节点域名，例如 jp1.aa.com。
REALITY 的 SNI 不一定是 jp1.aa.com，而是脚本选择的 REALITY_SNI。
这不是写错。
~~~

---

### 2. Hysteria 2

客户端配置文件：

~~~bash
cat /opt/proxy-stack-jp1-aa-com/clients/hysteria2-client.yaml
~~~

大致格式：

~~~yaml
server: "hysteria2://your_auth@jp1.aa.com:40000-50000/?sni=jp1.aa.com&insecure=0&obfs=salamander&obfs-password=your_obfs_password"

transport:
  type: udp
  udp:
    minHopInterval: 15s
    maxHopInterval: 45s

bandwidth:
  up: 1 gbps
  down: 1 gbps
~~~

---

## 十一、常用管理命令

进入安装目录：

~~~bash
cd /opt/proxy-stack-jp1-aa-com
~~~

查看状态：

~~~bash
docker compose ps
~~~

查看日志：

~~~bash
docker compose logs -f --tail=100
~~~

只看 Xray 日志：

~~~bash
docker compose logs -f --tail=100 xray
~~~

只看 Hysteria 日志：

~~~bash
docker compose logs -f --tail=100 hysteria
~~~

重启：

~~~bash
docker compose restart
~~~

停止：

~~~bash
docker compose down
~~~

启动：

~~~bash
docker compose up -d
~~~

升级镜像：

~~~bash
docker compose pull
docker compose up -d
~~~

---

## 十二、证书续期

脚本使用：

~~~text
acme.sh + Cloudflare DNS-01
~~~

签发证书。

证书安装位置：

~~~text
/opt/proxy-stack-域名/certs/fullchain.pem
/opt/proxy-stack-域名/certs/privkey.pem
~~~

续期后会自动执行：

~~~bash
cd /opt/proxy-stack-域名 && docker compose restart hysteria
~~~

Xray REALITY 不依赖这个证书，所以证书续期只需要重启 Hysteria。

手动强制续期：

~~~bash
~/.acme.sh/acme.sh --renew -d jp1.aa.com --ecc --force
~~~

---

## 十三、IPv6 说明

脚本会自动尝试：

~~~bash
curl -4 https://api.ipify.org
curl -6 https://api64.ipify.org
~~~

如果检测到 IPv4：

~~~text
写入 A 记录
~~~

如果检测到 IPv6 且 ENABLE_IPV6=true：

~~~text
写入 AAAA 记录
~~~

如果 VPS 没有 IPv6：

~~~text
跳过 AAAA，不影响部署
~~~

Xray 使用：

~~~json
"listen": "::"
~~~

并且 Docker 使用：

~~~yaml
network_mode: "host"
~~~

这样更适合双栈监听。

Hysteria 2 同样使用 host 网络。

部署后检查：

~~~bash
ss -lntup | grep 24443
ss -lnuup | grep 40000
~~~

如果 IPv6 连不上，优先检查：

~~~text
1. 云厂商是否给 VPS 分配 IPv6
2. Cloudflare 是否成功写入 AAAA
3. 云厂商 IPv6 安全组是否放行
4. 系统防火墙是否放行 IPv6 入站
5. 本地客户端网络是否支持 IPv6
~~~

---

## 十四、Cloudflare 注意事项

脚本会强制把节点域名设置为：

~~~text
DNS only / 灰云
~~~

原因：

~~~text
Xray 使用自定义 TCP 高位端口
Hysteria 2 使用 UDP 高位端口范围
Cloudflare 普通橙云代理不适合直接代理这些端口
~~~

如果节点域名被设置成橙云，通常会导致：

~~~text
Xray 连接异常
Hysteria 2 无法连接
UDP 不通
高位端口不通
~~~

所以节点域名必须灰云。

主站域名可以继续橙云，例如：

~~~text
aa.com      橙云，给网站
www.aa.com  橙云，给网站
jp1.aa.com  灰云，给代理节点
~~~

---

## 十五、与 1Panel / OpenResty 共存说明

本方案不会修改：

~~~text
1Panel
OpenResty
Nginx 配置
80/tcp
443/tcp
网站反代
已有容器
~~~

默认新增使用：

~~~text
24443/tcp
40000-50000/udp
~~~

因此：

~~~text
1Panel 继续管理网站
OpenResty 继续监听 80/443
代理服务独立运行
后续继续安装网站和容器不受影响
~~~

但要注意：

~~~text
不要让其他容器占用 24443/tcp
不要让其他 UDP 服务占用 40000-50000/udp
~~~

如果 40000-50000 还要给别的服务用，可以部署时改成更小范围，例如：

~~~bash
bash /root/install-proxy-stack.sh jp1.aa.com 24443 45000-50000
~~~

---

## 十六、多 VPS 部署示例

日本 VPS：

~~~bash
bash /root/install-proxy-stack.sh jp1.aa.com
~~~

新加坡 VPS：

~~~bash
bash /root/install-proxy-stack.sh sg1.aa.com
~~~

美国 VPS：

~~~bash
bash /root/install-proxy-stack.sh us1.aa.com
~~~

香港 VPS：

~~~bash
bash /root/install-proxy-stack.sh hk1.aa.com
~~~

每台 VPS 都使用自己的子域名。

不要多台 VPS 使用同一个节点域名，否则 Cloudflare DNS 会被最后一台执行脚本的 VPS 覆盖。

---

## 十七、重复执行脚本会发生什么

脚本是尽量幂等的。

重复执行：

~~~bash
bash /root/install-proxy-stack.sh jp1.aa.com
~~~

会：

~~~text
更新 Cloudflare DNS
检查证书
重写 docker-compose.yml
重写 Xray 配置
重写 Hysteria 配置
重启容器
~~~

不会随便重置：

~~~text
Xray UUID
REALITY private key
REALITY public key
REALITY shortId
XHTTP path
Hysteria 密码
Hysteria obfs 密码
REALITY SNI
~~~

这些都保存在：

~~~text
/opt/proxy-stack-jp1-aa-com/secrets.env
~~~

如果你真的想重置所有客户端参数，可以停止服务后删除：

~~~bash
bash /root/install-proxy-stack.sh cleanup jp1.aa.com
bash /root/install-proxy-stack.sh jp1.aa.com
~~~

注意：

~~~text
清理后旧客户端全部失效
Cloudflare A/AAAA 记录会被一起删除
acme.sh 中该域名证书也会被一起清掉
~~~

---

## 十八、卸载

以 `jp1.aa.com` 为例：

~~~bash
bash /root/install-proxy-stack.sh cleanup jp1.aa.com
~~~

该命令会自动执行：

~~~text
停止并删除 Docker Compose 服务
删除 /opt/proxy-stack-对应域名 目录
删除 Cloudflare 中该域名的 A / AAAA 记录
删除 ~/.acme.sh/该域名_ecc 证书目录
~~~

说明：

~~~text
如果没有提供 CF_TOKEN，则会跳过 Cloudflare DNS 清理
cleanup / uninstall / purge 三个命令等价
~~~

或者自行通过 API 删除。

---

## 十九、常见问题

### 1. Hysteria 2 日志提示端口跳跃失败

检查：

~~~bash
docker compose logs -f hysteria
~~~

常见原因：

~~~text
没有 NET_ADMIN 权限
没有使用 network_mode: host
系统缺少 nftables/iptables
端口范围被其他程序占用
~~~

本脚本已经默认配置：

~~~yaml
network_mode: "host"
cap_add:
  - NET_ADMIN
~~~

---

### 2. Hysteria 2 只看到 40000 端口监听，没看到整个范围

这是正常现象。

端口跳跃通常只会看到首个端口由程序监听，其余端口通过 nftables/iptables 重定向。

检查：

~~~bash
ss -lnuup | grep 40000
~~~

---

### 3. Xray 无法连接

检查：

~~~bash
cd /opt/proxy-stack-jp1-aa-com
docker compose logs -f xray
~~~

确认客户端参数：

~~~text
address 是否是 jp1.aa.com
port 是否是 24443
uuid 是否正确
network 是否是 xhttp
path 是否包含前导 /
security 是否是 reality
sni 是否是 client-info.txt 里的 REALITY SNI
publicKey 是否是 client-info.txt 里的 publicKey
shortId 是否正确
fingerprint 是否是 chrome
flow 是否留空
~~~

---

### 4. Cloudflare DNS 更新失败

检查：

~~~text
CF_TOKEN 是否正确
Token 是否有 Zone Read 权限
Token 是否有 DNS Edit 权限
Token 是否授权了对应根域名
域名是否真的托管在 Cloudflare
~~~

---

### 5. acme.sh 证书申请失败

检查：

~~~text
CF_TOKEN 是否有 DNS Edit 权限
域名 Zone 是否正确
DNS 是否由 Cloudflare 管理
服务器时间是否正确
是否过于频繁申请触发限额
~~~

可以查看 acme.sh 日志：

~~~bash
~/.acme.sh/acme.sh --debug --issue --dns dns_cf -d jp1.aa.com --keylength ec-256
~~~

---

### 6. IPv6 不通

检查服务器是否有 IPv6：

~~~bash
ip -6 addr
curl -6 https://api64.ipify.org
~~~

如果 curl -6 失败，说明 VPS 当前没有可用 IPv6 出口，脚本会自动跳过 AAAA。

---

### 7. 1Panel 后续还能不能继续安装网站？

可以。

因为本方案不占用：

~~~text
80/tcp
443/tcp
~~~

1Panel / OpenResty 可以继续管理网站。

只要避免占用：

~~~text
24443/tcp
40000-50000/udp
~~~

即可。

---

## 二十、推荐最终部署流程总结

每台 VPS 执行：

~~~bash
curl -fsSL https://get.docker.com | bash
systemctl enable docker
systemctl start docker
~~~

创建公共配置：

~~~bash
cat > /root/proxy-global.env <<'EOF'
EMAIL="你的邮箱@example.com"
CF_TOKEN="你的Cloudflare_API_Token"

DEFAULT_XRAY_PORT="24443"
DEFAULT_HY2_PORT_RANGE="40000-50000"

ENABLE_IPV6="true"

REALITY_SNI_POOL="www.oracle.com,www.ibm.com,www.samsung.com,www.lg.com,developer.mozilla.org,source.android.com,www.intel.com,www.amd.com,www.lenovo.com,www.dell.com"
EOF

chmod 600 /root/proxy-global.env
~~~

创建脚本：

~~~bash
wget -O /root/install-proxy-stack.sh --no-check-certificate \
  https://raw.githubusercontent.com/feng005211/simple-proxy-2-docker/main/install-proxy-stack.sh && \
chmod 700 /root/install-proxy-stack.sh
~~~

部署节点：

~~~bash
bash /root/install-proxy-stack.sh jp1.aa.com
~~~

查看客户端信息：

~~~bash
cat /opt/proxy-stack-jp1-aa-com/client-info.txt
~~~

查看服务状态：

~~~bash
cd /opt/proxy-stack-jp1-aa-com
docker compose ps
~~~

升级：

~~~bash
cd /opt/proxy-stack-jp1-aa-com
docker compose pull
docker compose up -d
~~~

---

## 二十一、最终架构

~~~text
Cloudflare
├─ aa.com / www.aa.com
│  └─ 可继续橙云，给 1Panel 网站
│
├─ jp1.aa.com
│  ├─ A    -> VPS IPv4，DNS only
│  └─ AAAA -> VPS IPv6，DNS only
│
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
      └─ port hopping
~~~
