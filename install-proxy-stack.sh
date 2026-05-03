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
HY2_BANDWIDTH_UP="${HY2_BANDWIDTH_UP:-1 gbps}"
HY2_BANDWIDTH_DOWN="${HY2_BANDWIDTH_DOWN:-1 gbps}"
HY2_CLIENT_BANDWIDTH_UP="${HY2_CLIENT_BANDWIDTH_UP:-1 gbps}"
HY2_CLIENT_BANDWIDTH_DOWN="${HY2_CLIENT_BANDWIDTH_DOWN:-1 gbps}"
HY2_QUIC_INIT_STREAM_WINDOW="${HY2_QUIC_INIT_STREAM_WINDOW:-8388608}"
HY2_QUIC_MAX_STREAM_WINDOW="${HY2_QUIC_MAX_STREAM_WINDOW:-16777216}"
HY2_QUIC_INIT_CONN_WINDOW="${HY2_QUIC_INIT_CONN_WINDOW:-20971520}"
HY2_QUIC_MAX_CONN_WINDOW="${HY2_QUIC_MAX_CONN_WINDOW:-41943040}"
HY2_MAX_IDLE_TIMEOUT="${HY2_MAX_IDLE_TIMEOUT:-60s}"
HY2_SYSCTL_RMEM_MAX="${HY2_SYSCTL_RMEM_MAX:-16777216}"
HY2_SYSCTL_WMEM_MAX="${HY2_SYSCTL_WMEM_MAX:-16777216}"

# Optional. If REALITY_SNI or REALITY_TARGET is set in /root/proxy-global.env,
# the script will respect it. Otherwise it will randomly select one item below
# on first deployment and persist it in secrets.env.
REALITY_SNI_POOL="${REALITY_SNI_POOL:-www.oracle.com,www.ibm.com,www.samsung.com,www.lg.com,developer.mozilla.org,source.android.com,www.intel.com,www.amd.com,www.lenovo.com,www.dell.com}"
LINUX_NETSPEED_REPO_URL="https://github.com/ylx2016/Linux-NetSpeed"
LINUX_NETSPEED_BBR_URL="https://github.com/ylx2016/Linux-NetSpeed/raw/master/tcpx.sh"
LINUX_NETSPEED_DD_URL="https://github.com/ylx2016/Linux-NetSpeed/raw/master/tcp.sh"

usage() {
  cat <<USAGE
Usage:
  bash $0 <domain> [xray_tcp_port] [hysteria_udp_port_or_range]
  bash $0 cleanup <domain>
  bash $0 uninstall <domain>
  bash $0 purge <domain>
  bash $0 bbr
  bash $0 dd

Examples:
  bash $0 jp1.example.com
  bash $0 sg1.example.com 24443 40000-50000
  bash $0 hk1.example.com 24443 10001
  bash $0 cleanup jp1.example.com
  bash $0 bbr
  bash $0 dd

Required environment variables, or put them in /root/proxy-global.env:
  EMAIL="you@example.com"
  CF_TOKEN="Cloudflare API Token"

Optional environment variables:
  DEFAULT_XRAY_PORT="24443"
  DEFAULT_HY2_PORT_RANGE="40000-50000"
  ENABLE_IPV6="true"                 # true/false; true means create AAAA when IPv6 is detected
  HY2_BANDWIDTH_UP="1 gbps"          # Hysteria 2 server-side upload cap per client
  HY2_BANDWIDTH_DOWN="1 gbps"        # Hysteria 2 server-side download cap per client
  HY2_CLIENT_BANDWIDTH_UP="1 gbps"   # default value written into Hysteria client templates
  HY2_CLIENT_BANDWIDTH_DOWN="1 gbps" # default value written into Hysteria client templates
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
  - bbr / dd entries use the mature work by [ylx2016]:
    https://github.com/ylx2016/Linux-NetSpeed
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
  bbr|dd)
    ACTION="${1:-}"
    shift
    ;;
esac

DOMAIN="${1:-}"
XRAY_PORT="${2:-$DEFAULT_XRAY_PORT}"
HY2_PORT_RANGE="${3:-$DEFAULT_HY2_PORT_RANGE}"
HY2_UFW_PORT_SPEC="${HY2_PORT_RANGE/-/:}"

if [ "$ACTION" != "bbr" ] && [ "$ACTION" != "dd" ] && [ -z "$DOMAIN" ]; then
  usage
  exit 1
fi

if [ "$ACTION" != "bbr" ] && [ "$ACTION" != "dd" ]; then
  DOMAIN="$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed 's/\.$//')"
  export DOMAIN
  MASQUERADE_URL="${MASQUERADE_URL:-https://${DOMAIN}/}"
  SAFE_DOMAIN="${DOMAIN//./-}"
  INSTALL_DIR="${INSTALL_DIR:-/opt/proxy-stack-${SAFE_DOMAIN}}"
  SECRETS_FILE="${INSTALL_DIR}/secrets.env"
  ACME_CERT_DIR="$HOME/.acme.sh/${DOMAIN}_ecc"
  XRAY_CONTAINER_NAME="xray-reality-xhttp-${SAFE_DOMAIN}"
  HY2_CONTAINER_NAME="hysteria2-hop-${SAFE_DOMAIN}"
fi

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

if [ "$ACTION" != "bbr" ] && [ "$ACTION" != "dd" ]; then
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
    if re.fullmatch(r"\d{1,5}", hy2_range):
        a = b = int(hy2_range)
    elif re.fullmatch(r"\d{1,5}-\d{1,5}", hy2_range):
        a, b = map(int, hy2_range.split("-"))
    else:
        raise SystemExit(f"Hysteria 端口或范围格式不正确: {hy2_range}")
    if not (1 <= a <= b <= 65535):
        raise SystemExit(f"Hysteria 端口或范围不正确: {hy2_range}")
PY
fi

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

install_fetch_deps() {
  local missing=()
  for cmd in ca-certificates; do
    :
  done

  if need_cmd curl || need_cmd wget; then
    return 0
  fi

  log "安装下载依赖"
  if need_cmd apt-get; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl wget
  elif need_cmd dnf; then
    dnf install -y ca-certificates curl wget
  elif need_cmd yum; then
    yum install -y ca-certificates curl wget
  else
    echo "无法自动安装下载依赖，请先安装 curl 或 wget 后重试。" >&2
    exit 1
  fi
}

apply_hysteria_sysctl_tuning() {
  local sysctl_file="/etc/sysctl.d/99-proxy-stack-hysteria.conf"

  if ! need_cmd sysctl; then
    echo "未检测到 sysctl，跳过 Hysteria 性能 sysctl 优化。" >&2
    return 0
  fi

  log "应用 Hysteria 性能优化 sysctl"
  cat > "$sysctl_file" <<EOF
# Managed by install-proxy-stack.sh
# Recommended by Hysteria 2 performance guide for larger UDP socket buffers.
net.core.rmem_max=${HY2_SYSCTL_RMEM_MAX}
net.core.wmem_max=${HY2_SYSCTL_WMEM_MAX}
EOF

  sysctl -w "net.core.rmem_max=${HY2_SYSCTL_RMEM_MAX}" >/dev/null
  sysctl -w "net.core.wmem_max=${HY2_SYSCTL_WMEM_MAX}" >/dev/null
  echo "已写入 ${sysctl_file}"
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

  python3 - "$REALITY_SNI_POOL" <<'PY'
import random, re, sys
pool = sys.argv[1]
items = [x.strip() for x in re.split(r'[, \t\r\n]+', pool) if x.strip()]
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

generate_reality_keypair() {
  local xray_keys
  xray_keys="$(docker run --rm ghcr.io/xtls/xray-core:latest x25519)"

  mapfile -t _reality_keypair < <(printf '%s' "$xray_keys" | python3 -c '
import re, sys
text = sys.stdin.read()
priv = re.search(r"Private(?:\s*key)?\s*:\s*(\S+)", text, re.IGNORECASE)
pub = re.search(r"(?:Public\s*key|Password\s*\(PublicKey\))\s*:\s*(\S+)", text, re.IGNORECASE)
if not priv or not pub:
    print(text, file=sys.stderr)
    raise SystemExit("无法从 x25519 输出中解析 REALITY 密钥")
print(priv.group(1))
print(pub.group(1))
')

  REALITY_PRIVATE_KEY="${_reality_keypair[0]:-}"
  REALITY_PUBLIC_KEY="${_reality_keypair[1]:-}"

  if [ -z "$REALITY_PRIVATE_KEY" ] || [ -z "$REALITY_PUBLIC_KEY" ]; then
    echo "生成 REALITY 密钥失败：privateKey/publicKey 为空" >&2
    exit 1
  fi
}

write_secrets_file() {
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
}

regenerate_broken_secrets_if_needed() {
  if [ -n "${XRAY_UUID:-}" ] && [ -n "${REALITY_PRIVATE_KEY:-}" ] && [ -n "${REALITY_PUBLIC_KEY:-}" ] && \
     [ -n "${SHORT_ID:-}" ] && [ -n "${XHTTP_PATH:-}" ] && [ -n "${HY2_PASSWORD:-}" ] && \
     [ -n "${HY2_OBFS_PASSWORD:-}" ]; then
    return 0
  fi

  echo "检测到 secrets.env 缺少关键字段，自动重新生成缺失密钥与凭据"
  XRAY_UUID="${XRAY_UUID:-$(docker run --rm ghcr.io/xtls/xray-core:latest uuid)}"
  generate_reality_keypair
  SHORT_ID="${SHORT_ID:-$(openssl rand -hex 8)}"
  XHTTP_PATH="${XHTTP_PATH:-/$(openssl rand -hex 10)}"
  HY2_PASSWORD="${HY2_PASSWORD:-$(openssl rand -hex 24)}"
  HY2_OBFS_PASSWORD="${HY2_OBFS_PASSWORD:-$(openssl rand -hex 24)}"
  REALITY_SNI_CHOSEN="${REALITY_SNI_CHOSEN:-$(choose_reality_sni)}"
  REALITY_TARGET_CHOSEN="${REALITY_TARGET_CHOSEN:-$(choose_reality_target "$REALITY_SNI_CHOSEN")}"
  write_secrets_file
}

download_remote_script() {
  local url="$1"
  local target="$2"
  if need_cmd wget; then
    wget -O "$target" --no-check-certificate "$url"
  elif need_cmd curl; then
    curl -fsSL -o "$target" "$url"
  else
    install_fetch_deps
    download_remote_script "$url" "$target"
  fi
}

run_external_tool() {
  local tool_name="$1"
  local script_url="$2"
  local target_path="/tmp/$(basename "$script_url")"

  log "启动 ${tool_name} 工具"
  echo "BBR、DD 脚本用的 [ylx2016] 的成熟作品，地址 [${LINUX_NETSPEED_REPO_URL}]，请熟知。"
  echo "提示：这里的 dd 入口对应 Linux-NetSpeed 的替换内核版脚本，不是系统重装 DD 工具。"
  echo "即将下载并运行：${script_url}"

  download_remote_script "$script_url" "$target_path"
  chmod 700 "$target_path"
  "$target_path"
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
import json, sys
DOMAIN = sys.argv[1].rstrip(".")
j = json.load(sys.stdin)
matches = []
for z in j.get("result", []):
    name = z.get("name", "").rstrip(".")
    if DOMAIN == name or DOMAIN.endswith("." + name):
        matches.append((len(name), z.get("id", ""), name))
if matches:
    matches.sort(reverse=True)
    print(matches[0][1])
' "$DOMAIN" )"
  ZONE_NAME="$(printf '%s' "$ZONES_JSON" | python3 -c '
import json, sys
DOMAIN = sys.argv[1].rstrip(".")
j = json.load(sys.stdin)
matches = []
for z in j.get("result", []):
    name = z.get("name", "").rstrip(".")
    if DOMAIN == name or DOMAIN.endswith("." + name):
        matches.append((len(name), z.get("id", ""), name))
if matches:
    matches.sort(reverse=True)
    print(matches[0][2])
' "$DOMAIN" )"

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

if [ "$ACTION" = "bbr" ]; then
  run_external_tool "BBR" "$LINUX_NETSPEED_BBR_URL"
  exit 0
fi

if [ "$ACTION" = "dd" ]; then
  run_external_tool "DD" "$LINUX_NETSPEED_DD_URL"
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

apply_hysteria_sysctl_tuning

log "生成或复用密钥与 REALITY 目标"
if [ ! -f "$SECRETS_FILE" ]; then
  XRAY_UUID="$(docker run --rm ghcr.io/xtls/xray-core:latest uuid)"
  generate_reality_keypair
  SHORT_ID="$(openssl rand -hex 8)"
  XHTTP_PATH="/$(openssl rand -hex 10)"
  HY2_PASSWORD="$(openssl rand -hex 24)"
  HY2_OBFS_PASSWORD="$(openssl rand -hex 24)"
  REALITY_SNI_CHOSEN="$(choose_reality_sni)"
  REALITY_TARGET_CHOSEN="$(choose_reality_target "$REALITY_SNI_CHOSEN")"
  write_secrets_file
  echo "已生成新密钥，并选择 REALITY SNI: ${REALITY_SNI_CHOSEN}"
else
  echo "检测到已有 secrets.env，复用旧密钥"
fi
# shellcheck disable=SC1090
source "$SECRETS_FILE"
regenerate_broken_secrets_if_needed

# Backward compatibility for older or partially broken secrets.env files.
if [ -z "${REALITY_SNI_CHOSEN:-}" ]; then
  REALITY_SNI_CHOSEN="$(choose_reality_sni)"
  echo "已为旧配置补充 REALITY SNI: ${REALITY_SNI_CHOSEN}"
fi
if [ -z "${REALITY_TARGET_CHOSEN:-}" ]; then
  REALITY_TARGET_CHOSEN="$(choose_reality_target "$REALITY_SNI_CHOSEN")"
  echo "已为旧配置补充 REALITY target: ${REALITY_TARGET_CHOSEN}"
fi
write_secrets_file

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
  initStreamReceiveWindow: ${HY2_QUIC_INIT_STREAM_WINDOW}
  maxStreamReceiveWindow: ${HY2_QUIC_MAX_STREAM_WINDOW}
  initConnReceiveWindow: ${HY2_QUIC_INIT_CONN_WINDOW}
  maxConnReceiveWindow: ${HY2_QUIC_MAX_CONN_WINDOW}
  maxIdleTimeout: ${HY2_MAX_IDLE_TIMEOUT}
  maxIncomingStreams: 1024

bandwidth:
  up: ${HY2_BANDWIDTH_UP}
  down: ${HY2_BANDWIDTH_DOWN}
HY2

log "生成客户端配置说明"
PY_URI_FIELDS="$(python3 - <<PY
from urllib.parse import quote
print(quote("${XHTTP_PATH}", safe=''))
print(quote("${HY2_PASSWORD}", safe=''))
print(quote("${HY2_OBFS_PASSWORD}", safe=''))
print(quote("${DOMAIN}-hysteria2", safe=''))
PY
)"
PY_HY2_BANDWIDTH_FIELDS="$(python3 - "$HY2_CLIENT_BANDWIDTH_UP" "$HY2_CLIENT_BANDWIDTH_DOWN" <<'PY'
import re
import sys

UNITS = {
    "bps": 1 / 1_000_000,
    "b": 1 / 1_000_000,
    "kbps": 1 / 1_000,
    "kb": 1 / 1_000,
    "k": 1 / 1_000,
    "mbps": 1,
    "mb": 1,
    "m": 1,
    "gbps": 1_000,
    "gb": 1_000,
    "g": 1_000,
    "tbps": 1_000_000,
    "tb": 1_000_000,
    "t": 1_000_000,
}

def to_mbps(raw: str) -> float:
    text = raw.strip().lower()
    match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)\s*([a-z]+)", text)
    if not match:
        raise SystemExit(f"无法解析 Hysteria 带宽值: {raw}")
    value = float(match.group(1))
    unit = match.group(2)
    if unit not in UNITS:
        raise SystemExit(f"不支持的 Hysteria 带宽单位: {raw}")
    return value * UNITS[unit]

def to_human(mbps: float) -> str:
    if mbps >= 1000 and abs(mbps % 1000) < 1e-9:
        return f"{int(mbps / 1000)} Gbps"
    if abs(mbps - round(mbps)) < 1e-9:
        return f"{int(round(mbps))} Mbps"
    return f"{mbps:g} Mbps"

for raw in sys.argv[1:]:
    mbps = to_mbps(raw)
    if abs(mbps - round(mbps)) < 1e-9:
        print(int(round(mbps)))
    else:
        print(f"{mbps:g}")
    print(to_human(mbps))
PY
)"
PY_URLENCODED_PATH="$(printf '%s\n' "$PY_URI_FIELDS" | sed -n '1p')"
HY2_AUTH_ENCODED="$(printf '%s\n' "$PY_URI_FIELDS" | sed -n '2p')"
HY2_OBFS_PASSWORD_ENCODED="$(printf '%s\n' "$PY_URI_FIELDS" | sed -n '3p')"
HY2_TAG_ENCODED="$(printf '%s\n' "$PY_URI_FIELDS" | sed -n '4p')"
HY2_CLIENT_UP_MBPS="$(printf '%s\n' "$PY_HY2_BANDWIDTH_FIELDS" | sed -n '1p')"
HY2_CLIENT_UP_HUMAN="$(printf '%s\n' "$PY_HY2_BANDWIDTH_FIELDS" | sed -n '2p')"
HY2_CLIENT_DOWN_MBPS="$(printf '%s\n' "$PY_HY2_BANDWIDTH_FIELDS" | sed -n '3p')"
HY2_CLIENT_DOWN_HUMAN="$(printf '%s\n' "$PY_HY2_BANDWIDTH_FIELDS" | sed -n '4p')"
HY2_URI_PORT="${HY2_PORT_RANGE%%-*}"
HY2_HAS_PORT_RANGE=0
HY2_SINGBOX_PORTS=""
HY2_MIHOMO_PORT_FIELD="port: ${HY2_URI_PORT}"
HY2_SHARE_QUERY="sni=${DOMAIN}&insecure=0&allowInsecure=0&obfs=salamander&obfs-password=${HY2_OBFS_PASSWORD_ENCODED}"
if [[ "$HY2_PORT_RANGE" == *-* ]]; then
  HY2_HAS_PORT_RANGE=1
  HY2_SINGBOX_PORTS="${HY2_PORT_RANGE/-/:}"
  HY2_SHARE_QUERY="${HY2_SHARE_QUERY}&mport=${HY2_PORT_RANGE}"
  HY2_MIHOMO_PORT_FIELD="$(cat <<PORTS
port: ${HY2_URI_PORT}
    ports: ${HY2_PORT_RANGE}
PORTS
)"
fi
TAG="${DOMAIN}-vless-reality-xhttp"
VLESS_URI="vless://${XRAY_UUID}@${DOMAIN}:${XRAY_PORT}?encryption=none&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORT_ID}&type=xhttp&path=${PY_URLENCODED_PATH}#${TAG}"
HY2_URI_BASE="hysteria2://${HY2_AUTH_ENCODED}@${DOMAIN}:${HY2_PORT_RANGE}/?sni=${DOMAIN}&insecure=0&obfs=salamander&obfs-password=${HY2_OBFS_PASSWORD_ENCODED}"
HY2_SHARE_URI="hysteria2://${HY2_AUTH_ENCODED}@${DOMAIN}:${HY2_URI_PORT}?${HY2_SHARE_QUERY}#${HY2_TAG_ENCODED}"
CLASH_VLESS_NAME="${DOMAIN}-vless-reality-xhttp"
CLASH_HY2_NAME="${DOMAIN}-hysteria2"

cat > "${INSTALL_DIR}/clients/hysteria2-client.yaml" <<HY2CLIENT
server: "${HY2_URI_BASE}"
HY2CLIENT
if [ "$HY2_HAS_PORT_RANGE" = "1" ]; then
  cat >> "${INSTALL_DIR}/clients/hysteria2-client.yaml" <<HY2CLIENT
transport:
  type: udp
  udp:
    minHopInterval: 15s
    maxHopInterval: 45s
HY2CLIENT
fi
cat >> "${INSTALL_DIR}/clients/hysteria2-client.yaml" <<HY2CLIENT

bandwidth:
  up: ${HY2_CLIENT_BANDWIDTH_UP}
  down: ${HY2_CLIENT_BANDWIDTH_DOWN}
HY2CLIENT

cat > "${INSTALL_DIR}/sing-box-client-info.json" <<SINGBOX
{
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "${CLASH_HY2_NAME}",
      "server": "${DOMAIN}",
      "server_port": ${HY2_URI_PORT},
SINGBOX
if [ "$HY2_HAS_PORT_RANGE" = "1" ]; then
  cat >> "${INSTALL_DIR}/sing-box-client-info.json" <<SINGBOX
      "server_ports": [
        "${HY2_SINGBOX_PORTS}"
      ],
      "hop_interval": "15s",
      "hop_interval_max": "45s",
SINGBOX
fi
cat >> "${INSTALL_DIR}/sing-box-client-info.json" <<SINGBOX
      "password": "${HY2_PASSWORD}",
      "obfs": {
        "type": "salamander",
        "password": "${HY2_OBFS_PASSWORD}"
      },
      "tls": {
        "enabled": true,
        "server_name": "${DOMAIN}",
        "insecure": false,
        "alpn": [
          "h3"
        ]
      },
      "up_mbps": ${HY2_CLIENT_UP_MBPS},
      "down_mbps": ${HY2_CLIENT_DOWN_MBPS}
    }
  ]
}
SINGBOX

cat > "${INSTALL_DIR}/clash-client-info.txt" <<CLASH
proxies:
  - name: "${CLASH_VLESS_NAME}"
    type: vless
    server: ${DOMAIN}
    port: ${XRAY_PORT}
    udp: true
    uuid: ${XRAY_UUID}
    tls: true
    servername: ${REALITY_SNI}
    client-fingerprint: chrome
    skip-cert-verify: false
    reality-opts:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${SHORT_ID}
    network: xhttp
    xhttp-opts:
      path: ${XHTTP_PATH}
      mode: auto

  - name: "${CLASH_HY2_NAME}"
    type: hysteria2
    server: ${DOMAIN}
    ${HY2_MIHOMO_PORT_FIELD}
    password: ${HY2_PASSWORD}
    obfs: salamander
    obfs-password: ${HY2_OBFS_PASSWORD}
    sni: ${DOMAIN}
    skip-cert-verify: false
    alpn:
      - h3
CLASH
if [ "$HY2_HAS_PORT_RANGE" = "1" ]; then
  cat >> "${INSTALL_DIR}/clash-client-info.txt" <<CLASH
    hop-interval: 30
CLASH
fi
cat >> "${INSTALL_DIR}/clash-client-info.txt" <<CLASH
    up: "${HY2_CLIENT_UP_HUMAN}"
    down: "${HY2_CLIENT_DOWN_HUMAN}"
CLASH

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
Bandwidth limit: up ${HY2_BANDWIDTH_UP} / down ${HY2_BANDWIDTH_DOWN}
Hysteria 2 Share URI:
${HY2_SHARE_URI}
Hysteria 2 Official Client YAML: ${INSTALL_DIR}/clients/hysteria2-client.yaml
Sing-box JSON: ${INSTALL_DIR}/sing-box-client-info.json
Clash / Mihomo YAML: ${INSTALL_DIR}/clash-client-info.txt
Applied sysctl tuning: net.core.rmem_max=${HY2_SYSCTL_RMEM_MAX}, net.core.wmem_max=${HY2_SYSCTL_WMEM_MAX}

========== Useful Commands ==========
cd ${INSTALL_DIR} && docker compose ps
cd ${INSTALL_DIR} && docker compose logs -f --tail=100
cd ${INSTALL_DIR} && docker compose pull && docker compose up -d
cat ${INSTALL_DIR}/client-info.txt
INFO
chmod 600 "${INSTALL_DIR}/client-info.txt" "${INSTALL_DIR}/clients/hysteria2-client.yaml" "${INSTALL_DIR}/clash-client-info.txt" "${INSTALL_DIR}/sing-box-client-info.json"

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
echo "  ufw allow ${HY2_UFW_PORT_SPEC}/udp"
echo
echo "IPv6 说明："
echo "  如果已检测到 Public IPv6，脚本已同步 AAAA 记录；请确认 VPS 安全组和系统防火墙同样允许 IPv6 入站。"
echo "  Xray 已使用 host network + listen ::，通常可同时监听 IPv4/IPv6；如系统启用了 net.ipv6.bindv6only=1，请手动检查监听情况。"
