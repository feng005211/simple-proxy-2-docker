#!/usr/bin/env bash
set -euo pipefail

# Proxy Stack Auto Installer v2
# VLESS + REALITY + XHTTP  +  Hysteria 2 with UDP port hopping
# Designed to coexist with 1Panel/OpenResty by avoiding ports 80/443.
# New in v2:
#   - IPv4 + IPv6 detection, Cloudflare A + AAAA sync
#   - Default Hysteria 2 UDP hopping range: 40000-50000
#   - REALITY SNI/target random selection from configurable pool, persisted per node
#   - Xray uses host network mode for more reliable IPv6 inbound support

ENV_FILE="/root/proxy-global.env"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"

DEFAULT_XRAY_PORT="${DEFAULT_XRAY_PORT:-24443}"
DEFAULT_HY2_PORT_RANGE="${DEFAULT_HY2_PORT_RANGE:-40000-50000}"
ENABLE_IPV6="${ENABLE_IPV6:-true}"

# Optional. If REALITY_SNI or REALITY_TARGET is set in /root/proxy-global.env,
# the script will respect it. Otherwise it will randomly select one item below
# on first deployment and persist it in secrets.env.
REALITY_SNI_POOL="${REALITY_SNI_POOL:-www.oracle.com,www.ibm.com,www.samsung.com,www.lg.com,developer.mozilla.org,source.android.com,www.intel.com,www.amd.com,www.lenovo.com,www.dell.com}"

usage() {
  cat <<USAGE
Usage:
  bash $0 <domain> [xray_tcp_port] [hysteria_udp_range]
  bash $0 cleanup <domain>
  bash $0 uninstall <domain>
  bash $0 purge <domain>

Examples:
  bash $0 jp1.example.com
  bash $0 sg1.example.com 24443 40000-50000
  bash $0 cleanup jp1.example.com

Required environment variables, or put them in /root/proxy-global.env:
  EMAIL="you@example.com"
  CF_TOKEN="Cloudflare API Token"

Optional environment variables:
  DEFAULT_XRAY_PORT="24443"
  DEFAULT_HY2_PORT_RANGE="40000-50000"
  ENABLE_IPV6="true"                 # true/false; true means create AAAA when IPv6 is detected
  PUBLIC_IPV4="1.2.3.4"              # override auto-detected IPv4
  PUBLIC_IPV6="2001:db8::1234"       # override auto-detected IPv6
  PUBLIC_IP="1.2.3.4"                # backward-compatible IPv4 override
  INSTALL_DIR="/opt/proxy-stack-custom"
  MASQUERADE_URL="https://your-real-site.example/"

  # REALITY options. If both are omitted, one SNI is randomly selected from REALITY_SNI_POOL.
  REALITY_SNI="www.example.com"
  REALITY_TARGET="www.example.com:443"
  REALITY_SNI_POOL="www.oracle.com,www.ibm.com,www.samsung.com"

Notes:
  - Cloudflare DNS records are forced to DNS only / gray cloud.
  - Hysteria 2 uses UDP port hopping only within the selected range.
  - Xray uses host network mode to avoid Docker IPv6 bridge limitations.
  - cleanup/uninstall/purge will stop containers, remove local files,
    delete Cloudflare A/AAAA records for the domain, and purge acme.sh cert data.
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

ACTION="install"
case "${1:-}" in
  cleanup|uninstall|purge)
    ACTION="cleanup"
    shift
    ;;
esac

DOMAIN="${1:-}"
XRAY_PORT="${2:-$DEFAULT_XRAY_PORT}"
HY2_PORT_RANGE="${3:-$DEFAULT_HY2_PORT_RANGE}"

if [ -z "$DOMAIN" ]; then
  usage
  exit 1
fi

DOMAIN="$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/\.$//')"
export DOMAIN
MASQUERADE_URL="${MASQUERADE_URL:-https://${DOMAIN}/}"
SAFE_DOMAIN="${DOMAIN//./-}"
INSTALL_DIR="${INSTALL_DIR:-/opt/proxy-stack-${SAFE_DOMAIN}}"
SECRETS_FILE="${INSTALL_DIR}/secrets.env"
ACME_CERT_DIR="$HOME/.acme.sh/${DOMAIN}_ecc"
XRAY_CONTAINER_NAME="xray-reality-xhttp-${SAFE_DOMAIN}"
HY2_CONTAINER_NAME="hysteria2-hop-${SAFE_DOMAIN}"

if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 执行：sudo bash $0 $DOMAIN $XRAY_PORT $HY2_PORT_RANGE" >&2
  exit 1
fi

if [ "$ACTION" = "install" ] && [ -z "${EMAIL:-}" ]; then
  echo "缺少 EMAIL。请在 /root/proxy-global.env 里填写 EMAIL=\"你的邮箱\"" >&2
  exit 1
fi

if [ "$ACTION" = "install" ] && [ -z "${CF_TOKEN:-}" ]; then
  echo "缺少 CF_TOKEN。请在 /root/proxy-global.env 里填写 CF_TOKEN=\"Cloudflare API Token\"" >&2
  exit 1
fi

python3 - "$ACTION" "$DOMAIN" "$XRAY_PORT" "$HY2_PORT_RANGE" <<'PY'
import re, sys
_, action, domain, xray_port, hy2_range = sys.argv
if not re.fullmatch(r"(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}", domain):
    raise SystemExit(f"域名格式不正确: {domain}")
if action == "install":
    try:
        p = int(xray_port)
        if not 1 <= p <= 65535:
            raise ValueError
    except ValueError:
        raise SystemExit(f"Xray 端口不正确: {xray_port}")
    if not re.fullmatch(r"\d{1,5}-\d{1,5}", hy2_range):
        raise SystemExit(f"Hysteria 端口范围格式不正确: {hy2_range}")
    a, b = map(int, hy2_range.split("-"))
    if not (1 <= a <= b <= 65535):
        raise SystemExit(f"Hysteria 端口范围不正确: {hy2_range}")
PY

log() {
  echo
  echo "==== $* ===="
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_basic_deps() {
  local missing=()
  for cmd in curl openssl python3; do
    need_cmd "$cmd" || missing+=("$cmd")
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    return 0
  fi

  log "安装基础依赖: ${missing[*]}"
  if need_cmd apt-get; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl openssl python3 ca-certificates
  elif need_cmd dnf; then
    dnf install -y curl openssl python3 ca-certificates
  elif need_cmd yum; then
    yum install -y curl openssl python3 ca-certificates
  else
    echo "无法自动安装依赖，请先安装: curl openssl python3 ca-certificates" >&2
    exit 1
  fi
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().rstrip("\n")))'
}

valid_ip_or_empty() {
  local ip="$1"
  local version="$2"
  [ -z "$ip" ] && return 0
  python3 - "$ip" "$version" <<'PY'
import ipaddress, sys
ip = sys.argv[1].strip()
version = int(sys.argv[2])
try:
    obj = ipaddress.ip_address(ip)
except ValueError:
    sys.exit(1)
sys.exit(0 if obj.version == version else 1)
PY
}

safe_rm_rf() {
  local target="$1"
  if [ -z "$target" ] || [ "$target" = "/" ]; then
    echo "拒绝删除危险路径: ${target}" >&2
    exit 1
  fi
  case "$target" in
    /opt/proxy-stack-*|"${HOME}"/.acme.sh/*_ecc)
      ;;
    *)
      echo "拒绝删除非脚本管理路径: ${target}" >&2
      echo "如使用了自定义 INSTALL_DIR，请先手动确认路径后自行删除。" >&2
      exit 1
      ;;
  esac
  rm -rf -- "$target"
}

choose_reality_sni() {
  if [ -n "${REALITY_SNI:-}" ]; then
    printf '%s' "$REALITY_SNI"
    return 0
  fi

  if [ -n "${REALITY_TARGET:-}" ]; then
    python3 - "$REALITY_TARGET" <<'PY'
import sys
s = sys.argv[1].strip()
if s.startswith('['):
    host = s[1:].split(']', 1)[0]
else:
    host = s.rsplit(':', 1)[0] if ':' in s else s
print(host)
PY
    return 0
  fi

  python3 - <<'PY'
import os, random, re
pool = os.environ.get('REALITY_SNI_POOL', '')
items = [x.strip() for x in re.split(r'[,
\t ]+', pool) if x.strip()]
if not items:
    raise SystemExit('REALITY_SNI_POOL 为空，无法随机选择 REALITY SNI')
print(random.choice(items))
PY
}

choose_reality_target() {
  local chosen_sni="$1"
  if [ -n "${REALITY_TARGET:-}" ]; then
    printf '%s' "$REALITY_TARGET"
  else
    printf '%s:443' "$chosen_sni"
  fi
}

CF_API="https://api.cloudflare.com/client/v4"

cf_api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"
  local response

  if [ -n "$data" ]; then
    response="$(curl -sS -X "$method" \
      -H "Authorization: Bearer ${CF_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$data" \
      "${CF_API}${endpoint}")"
  else
    response="$(curl -sS -X "$method" \
      -H "Authorization: Bearer ${CF_TOKEN}" \
      -H "Content-Type: application/json" \
      "${CF_API}${endpoint}")"
  fi

  printf '%s' "$response" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    j = json.loads(raw)
except Exception:
    print(raw, file=sys.stderr)
    raise
if not j.get("success", False):
    print("Cloudflare API error:", json.dumps(j.get("errors"), ensure_ascii=False), file=sys.stderr)
    sys.exit(1)
print(raw)
'
}

upsert_dns_record() {
  local record_type="$1"
  local record_content="$2"

  local records_json record_id payload
  records_json="$(cf_api GET "/zones/${ZONE_ID}/dns_records?type=${record_type}&name=${DOMAIN}")"
  record_id="$(printf '%s' "$records_json" | python3 -c '
import json, sys
j=json.load(sys.stdin)
for r in j.get("result", []):
    print(r.get("id", ""))
    break
')"

  payload="$(python3 - <<PY
import json
print(json.dumps({
  "type": "${record_type}",
  "name": "${DOMAIN}",
  "content": "${record_content}",
  "ttl": 120,
  "proxied": False
}))
PY
)"

  if [ -z "$record_id" ]; then
    cf_api POST "/zones/${ZONE_ID}/dns_records" "$payload" >/dev/null
    echo "已创建 ${record_type} 记录: ${DOMAIN} -> ${record_content}, DNS only"
  else
    cf_api PUT "/zones/${ZONE_ID}/dns_records/${record_id}" "$payload" >/dev/null
    echo "已更新 ${record_type} 记录: ${DOMAIN} -> ${record_content}, DNS only"
  fi

  local extra_count
  extra_count="$(printf '%s' "$records_json" | python3 -c '
import json, sys
j=json.load(sys.stdin)
print(max(0, len(j.get("result", [])) - 1))
')"
  if [ "$extra_count" != "0" ]; then
    echo "提示：检测到 ${extra_count} 条额外的同名 ${record_type} 记录，脚本未自动删除，避免误删。"
  fi
}

delete_dns_records_by_type() {
  local record_type="$1"
  local records_json
  records_json="$(cf_api GET "/zones/${ZONE_ID}/dns_records?type=${record_type}&name=${DOMAIN}")"
  printf '%s' "$records_json" | python3 -c '
import json, sys
j = json.load(sys.stdin)
for r in j.get("result", []):
    print(r.get("id", ""))
' | while IFS= read -r record_id; do
    [ -n "$record_id" ] || continue
    cf_api DELETE "/zones/${ZONE_ID}/dns_records/${record_id}" >/dev/null
    echo "已删除 ${record_type} 记录: ${DOMAIN}"
  done
}

resolve_zone_for_domain() {
  log "自动识别 Cloudflare Zone"
  ZONES_JSON="$(cf_api GET "/zones?per_page=100")"
  ZONE_ID="$(printf '%s' "$ZONES_JSON" | python3 -c '
import json, os, sys
DOMAIN = os.environ["DOMAIN"].rstrip(".")
j = json.load(sys.stdin)
matches = []
for z in j.get("result", []):
    name = z.get("name", "").rstrip(".")
    if DOMAIN == name or DOMAIN.endswith("." + name):
        matches.append((len(name), z.get("id", ""), name))
if matches:
    matches.sort(reverse=True)
    print(matches[0][1])
' )"
  ZONE_NAME="$(printf '%s' "$ZONES_JSON" | python3 -c '
import json, os, sys
DOMAIN = os.environ["DOMAIN"].rstrip(".")
j = json.load(sys.stdin)
matches = []
for z in j.get("result", []):
    name = z.get("name", "").rstrip(".")
    if DOMAIN == name or DOMAIN.endswith("." + name):
        matches.append((len(name), z.get("id", ""), name))
if matches:
    matches.sort(reverse=True)
    print(matches[0][2])
' )"

  if [ -z "${ZONE_ID:-}" ]; then
    echo "没有在 Cloudflare Token 权限内找到 ${DOMAIN} 对应的 Zone。" >&2
    echo "请确认 Token 有根域名的 Zone Read + DNS Edit 权限。" >&2
    exit 1
  fi

  echo "ZONE_NAME=${ZONE_NAME}"
  echo "ZONE_ID=${ZONE_ID}"
}

cleanup_stack() {
  log "开始彻底清理 ${DOMAIN}"
  echo "INSTALL_DIR=${INSTALL_DIR}"

  if need_cmd docker; then
    if docker compose version >/dev/null 2>&1 && [ -f "${INSTALL_DIR}/docker-compose.yml" ]; then
      log "停止并删除 Compose 服务"
      (
        cd "${INSTALL_DIR}"
        docker compose down --remove-orphans -v || true
      )
    else
      log "尝试删除已知容器"
      docker rm -f "${XRAY_CONTAINER_NAME}" "${HY2_CONTAINER_NAME}" >/dev/null 2>&1 || true
    fi
  else
    echo "未检测到 docker，跳过容器清理。"
  fi

  if [ -d "${INSTALL_DIR}" ]; then
    log "删除安装目录"
    safe_rm_rf "${INSTALL_DIR}"
    echo "已删除 ${INSTALL_DIR}"
  else
    echo "安装目录不存在，跳过本地文件清理。"
  fi

  if [ -n "${CF_TOKEN:-}" ]; then
    log "删除 Cloudflare DNS 记录"
    if need_cmd curl && need_cmd python3; then
      cf_api GET "/user/tokens/verify" >/dev/null
      resolve_zone_for_domain
      delete_dns_records_by_type "A"
      delete_dns_records_by_type "AAAA"
    else
      echo "缺少 curl 或 python3，跳过 Cloudflare DNS 清理。"
    fi
  else
    echo "未提供 CF_TOKEN，跳过 Cloudflare DNS 清理。"
  fi

  if [ -x "$HOME/.acme.sh/acme.sh" ]; then
    log "清理 acme.sh 证书与续期配置"
    "$HOME/.acme.sh/acme.sh" --remove -d "$DOMAIN" --ecc >/dev/null 2>&1 || true
  fi
  if [ -d "$ACME_CERT_DIR" ]; then
    safe_rm_rf "$ACME_CERT_DIR"
    echo "已删除 ${ACME_CERT_DIR}"
  else
    echo "未发现 acme.sh 域名目录，跳过。"
  fi

  echo
  echo "清理完成：${DOMAIN}"
}

if [ "$ACTION" = "cleanup" ]; then
  cleanup_stack
  exit 0
fi

install_basic_deps

if ! need_cmd docker; then
  echo "未检测到 docker。为了不影响 1Panel，本脚本不自动安装 Docker。请先安装 1Panel 或 Docker 后重试。" >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "未检测到 docker compose 插件。请先安装 Docker Compose plugin 后重试。" >&2
  exit 1
fi

log "验证 Cloudflare Token"
cf_api GET "/user/tokens/verify" >/dev/null

log "获取服务器公网 IPv4 / IPv6"
PUBLIC_IPV4="${PUBLIC_IPV4:-${PUBLIC_IP:-}}"
if [ -z "$PUBLIC_IPV4" ]; then
  PUBLIC_IPV4="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
fi
if ! valid_ip_or_empty "$PUBLIC_IPV4" 4; then
  echo "IPv4 探测结果无效，忽略: ${PUBLIC_IPV4}" >&2
  PUBLIC_IPV4=""
fi

PUBLIC_IPV6="${PUBLIC_IPV6:-}"
if [ "${ENABLE_IPV6}" != "false" ] && [ "${ENABLE_IPV6}" != "0" ] && [ -z "$PUBLIC_IPV6" ]; then
  PUBLIC_IPV6="$(curl -6fsS --max-time 10 https://api64.ipify.org 2>/dev/null || true)"
fi
if ! valid_ip_or_empty "$PUBLIC_IPV6" 6; then
  echo "IPv6 探测结果无效，忽略: ${PUBLIC_IPV6}" >&2
  PUBLIC_IPV6=""
fi

if [ -z "$PUBLIC_IPV4" ] && [ -z "$PUBLIC_IPV6" ]; then
  echo "未能探测到有效公网 IPv4 或 IPv6。你可以手动设置 PUBLIC_IPV4/PUBLIC_IPV6 后重试。" >&2
  exit 1
fi

echo "PUBLIC_IPV4=${PUBLIC_IPV4:-未检测到}"
echo "PUBLIC_IPV6=${PUBLIC_IPV6:-未检测到或未启用}"

resolve_zone_for_domain

log "检查同名 CNAME 冲突"
CONFLICTS_JSON="$(cf_api GET "/zones/${ZONE_ID}/dns_records?name=${DOMAIN}")"
CONFLICT_CNAME="$(printf '%s' "$CONFLICTS_JSON" | python3 -c '
import json, sys
j=json.load(sys.stdin)
for r in j.get("result", []):
    if r.get("type") == "CNAME":
        print(r.get("name", ""))
        break
')"
if [ -n "$CONFLICT_CNAME" ]; then
  echo "检测到同名 CNAME 记录：${CONFLICT_CNAME}" >&2
  echo "A/AAAA 记录不能和同名 CNAME 共存。请先在 Cloudflare 删除或改名这条 CNAME。" >&2
  exit 1
fi

log "创建/更新 Cloudflare A / AAAA 记录，强制 DNS only 灰云"
if [ -n "$PUBLIC_IPV4" ]; then
  upsert_dns_record "A" "$PUBLIC_IPV4"
else
  echo "未检测到 IPv4，跳过 A 记录。"
fi

if [ -n "$PUBLIC_IPV6" ]; then
  upsert_dns_record "AAAA" "$PUBLIC_IPV6"
else
  echo "未检测到 IPv6，跳过 AAAA 记录。"
fi

log "创建目录"
mkdir -p "${INSTALL_DIR}/xray" "${INSTALL_DIR}/hysteria" "${INSTALL_DIR}/certs" "${INSTALL_DIR}/clients"
chmod 700 "${INSTALL_DIR}"

echo "INSTALL_DIR=${INSTALL_DIR}"

log "生成或复用密钥与 REALITY 目标"
if [ ! -f "$SECRETS_FILE" ]; then
  XRAY_UUID="$(docker run --rm ghcr.io/xtls/xray-core:latest uuid)"
  XRAY_KEYS="$(docker run --rm ghcr.io/xtls/xray-core:latest x25519)"
  REALITY_PRIVATE_KEY="$(echo "$XRAY_KEYS" | awk '/Private key:/ {print $3}')"
  REALITY_PUBLIC_KEY="$(echo "$XRAY_KEYS" | awk '/Public key:/ {print $3}')"
  SHORT_ID="$(openssl rand -hex 8)"
  XHTTP_PATH="/$(openssl rand -hex 10)"
  HY2_PASSWORD="$(openssl rand -hex 24)"
  HY2_OBFS_PASSWORD="$(openssl rand -hex 24)"
  REALITY_SNI_CHOSEN="$(choose_reality_sni)"
  REALITY_TARGET_CHOSEN="$(choose_reality_target "$REALITY_SNI_CHOSEN")"

  cat > "$SECRETS_FILE" <<SECRETS
XRAY_UUID="${XRAY_UUID}"
REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY}"
REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY}"
SHORT_ID="${SHORT_ID}"
XHTTP_PATH="${XHTTP_PATH}"
HY2_PASSWORD="${HY2_PASSWORD}"
HY2_OBFS_PASSWORD="${HY2_OBFS_PASSWORD}"
REALITY_SNI_CHOSEN="${REALITY_SNI_CHOSEN}"
REALITY_TARGET_CHOSEN="${REALITY_TARGET_CHOSEN}"
SECRETS
  chmod 600 "$SECRETS_FILE"
  echo "已生成新密钥，并选择 REALITY SNI: ${REALITY_SNI_CHOSEN}"
else
  echo "检测到已有 secrets.env，复用旧密钥"
fi
# shellcheck disable=SC1090
source "$SECRETS_FILE"

# Backward compatibility for older secrets.env files created by v1.
if [ -z "${REALITY_SNI_CHOSEN:-}" ]; then
  REALITY_SNI_CHOSEN="$(choose_reality_sni)"
  REALITY_TARGET_CHOSEN="$(choose_reality_target "$REALITY_SNI_CHOSEN")"
  cat >> "$SECRETS_FILE" <<SECRETS
REALITY_SNI_CHOSEN="${REALITY_SNI_CHOSEN}"
REALITY_TARGET_CHOSEN="${REALITY_TARGET_CHOSEN}"
SECRETS
  echo "已为旧配置补充 REALITY SNI: ${REALITY_SNI_CHOSEN}"
fi

REALITY_SNI="$REALITY_SNI_CHOSEN"
REALITY_TARGET="$REALITY_TARGET_CHOSEN"

echo "REALITY_TARGET=${REALITY_TARGET}"
echo "REALITY_SNI=${REALITY_SNI}"

log "安装/配置 acme.sh 并签发证书"
if [ ! -x "$HOME/.acme.sh/acme.sh" ]; then
  curl https://get.acme.sh | sh -s email="$EMAIL"
fi

ACME="$HOME/.acme.sh/acme.sh"
export CF_Token="$CF_TOKEN"
"$ACME" --set-default-ca --server letsencrypt

ACME_CERT_DIR="$HOME/.acme.sh/${DOMAIN}_ecc"
if [ ! -f "${ACME_CERT_DIR}/${DOMAIN}.cer" ]; then
  "$ACME" --issue --dns dns_cf -d "$DOMAIN" --keylength ec-256
else
  echo "检测到 acme.sh 已有证书，跳过重新签发"
fi

"$ACME" --install-cert -d "$DOMAIN" --ecc \
  --fullchain-file "${INSTALL_DIR}/certs/fullchain.pem" \
  --key-file "${INSTALL_DIR}/certs/privkey.pem" \
  --reloadcmd "cd ${INSTALL_DIR} && docker compose restart hysteria >/dev/null 2>&1 || true"

chmod 600 "${INSTALL_DIR}/certs/privkey.pem"

log "写入 docker-compose.yml"
cat > "${INSTALL_DIR}/docker-compose.yml" <<COMPOSE
services:
  xray:
    image: ghcr.io/xtls/xray-core:latest
    container_name: xray-reality-xhttp-${SAFE_DOMAIN}
    restart: unless-stopped
    network_mode: "host"
    volumes:
      - ./xray/config.json:/etc/xray/config.json:ro
    command: ["run", "-config", "/etc/xray/config.json"]

  hysteria:
    image: tobyxdd/hysteria:latest
    container_name: hysteria2-hop-${SAFE_DOMAIN}
    restart: unless-stopped
    network_mode: "host"
    cap_add:
      - NET_ADMIN
    volumes:
      - ./hysteria/config.yaml:/etc/hysteria.yaml:ro
      - ./certs:/certs:ro
    command: ["server", "-c", "/etc/hysteria.yaml"]
COMPOSE

log "写入 Xray 配置"
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
          "target": "${REALITY_TARGET}",
          "serverNames": [
            "${REALITY_SNI}"
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

log "写入 Hysteria 2 配置"
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
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
HY2

log "生成客户端配置说明"
PY_URLENCODED_PATH="$(python3 - <<PY
from urllib.parse import quote
print(quote("${XHTTP_PATH}", safe=''))
PY
)"
TAG="${DOMAIN}-vless-reality-xhttp"
VLESS_URI="vless://${XRAY_UUID}@${DOMAIN}:${XRAY_PORT}?encryption=none&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=${PY_URLENCODED_PATH}#${TAG}"

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
  type: udp
  udp:
    minHopInterval: 15s
    maxHopInterval: 45s

bandwidth:
  up: 50 mbps
  down: 200 mbps
HY2CLIENT

cat > "${INSTALL_DIR}/client-info.txt" <<INFO
========== Basic ==========
Domain: ${DOMAIN}
Install dir: ${INSTALL_DIR}
Public IPv4: ${PUBLIC_IPV4:-none}
Public IPv6: ${PUBLIC_IPV6:-none}
Cloudflare Zone: ${ZONE_NAME}
DNS mode: DNS only / gray cloud
Hysteria masquerade URL: ${MASQUERADE_URL}

========== VLESS + REALITY + XHTTP ==========
Address: ${DOMAIN}
Port: ${XRAY_PORT}
UUID: ${XRAY_UUID}
Network: xhttp
XHTTP path: ${XHTTP_PATH}
Security: reality
REALITY target: ${REALITY_TARGET}
REALITY SNI / serverName: ${REALITY_SNI}
REALITY publicKey / password: ${REALITY_PUBLIC_KEY}
REALITY shortId: ${SHORT_ID}
Fingerprint: chrome
Flow: leave empty

VLESS URI:
${VLESS_URI}

========== Hysteria 2 ==========
Server: ${DOMAIN}:${HY2_PORT_RANGE}
Auth password: ${HY2_PASSWORD}
TLS SNI: ${DOMAIN}
Obfs type: salamander
Obfs password: ${HY2_OBFS_PASSWORD}
Client YAML: ${INSTALL_DIR}/clients/hysteria2-client.yaml

========== Useful Commands ==========
cd ${INSTALL_DIR} && docker compose ps
cd ${INSTALL_DIR} && docker compose logs -f --tail=100
cd ${INSTALL_DIR} && docker compose pull && docker compose up -d
cat ${INSTALL_DIR}/client-info.txt
INFO
chmod 600 "${INSTALL_DIR}/client-info.txt" "${INSTALL_DIR}/clients/hysteria2-client.yaml"

log "启动服务"
cd "$INSTALL_DIR"
docker compose pull
docker compose up -d

log "运行状态"
docker compose ps

echo
cat "${INSTALL_DIR}/client-info.txt"

echo
echo "部署完成。请确认 VPS 防火墙/安全组已放行："
echo "  TCP ${XRAY_PORT}"
echo "  UDP ${HY2_PORT_RANGE}"
echo
echo "如果使用 ufw，可以参考："
echo "  ufw allow ${XRAY_PORT}/tcp"
echo "  ufw allow ${HY2_PORT_RANGE}/udp"
echo
echo "IPv6 说明："
echo "  如果已检测到 Public IPv6，脚本已同步 AAAA 记录；请确认 VPS 安全组和系统防火墙同样允许 IPv6 入站。"
echo "  Xray 已使用 host network + listen ::，通常可同时监听 IPv4/IPv6；如系统启用了 net.ipv6.bindv6only=1，请手动检查监听情况。"
