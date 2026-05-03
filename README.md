# simple-proxy-2-docker

[中文文档](README.zh.md)

Self-hosted Xray and Hysteria 2 proxy stack for VPS nodes that already run 1Panel, OpenResty, or other services on `80/tcp` and `443/tcp`.

This project deploys a Docker Compose based node with:

- Xray: VLESS + REALITY + XHTTP
- Xray: VLESS + TCP + TLS + Vision
- Hysteria 2: UDP port hopping
- Cloudflare DNS automation for A / AAAA records
- acme.sh DNS-01 certificates through Cloudflare
- Generated client information for share links, Mihomo / Clash Meta, sing-box, and the official Hysteria 2 client

The main design goal is simple: add a practical multi-protocol proxy node to an existing VPS without taking over `80/tcp` or `443/tcp`.

---

## Why This Project

Many one-click proxy scripts assume a clean server and often want exclusive control over web ports. This script is built for the more common VPS reality: you may already have 1Panel, OpenResty, websites, dashboards, or other services running.

It keeps the proxy stack on separate ports, uses DNS-01 certificate issuance, writes Cloudflare DNS records in DNS-only mode, and leaves your existing web stack alone.

---

## Features

- Deploys VLESS REALITY/XHTTP, VLESS TCP/TLS Vision, and Hysteria 2 in one run
- Works alongside 1Panel / OpenResty because it does not bind `80/tcp` or `443/tcp`
- Detects public IPv4 / IPv6 and updates Cloudflare A / AAAA records
- Forces Cloudflare records to DNS only / gray cloud
- Issues and renews TLS certificates with acme.sh DNS-01
- Supports Hysteria 2 UDP port hopping, defaulting to `40000-50000/udp`
- Persists UUIDs, REALITY keys, Hysteria passwords, REALITY SNI, and XHTTP path
- Generates client output for common clients
- Supports `cleanup`, `uninstall`, and `purge`
- Uses Docker host networking to reduce IPv6 and UDP forwarding surprises

---

## Protocol Matrix

| Protocol | Default port | Transport | Security | Main use |
|---|---:|---|---|---|
| VLESS REALITY XHTTP | `24443/tcp` | XHTTP | REALITY | Main Xray fallback-resistant line |
| VLESS TCP TLS Vision | `23333/tcp` | TCP | TLS + Vision flow | Additional Xray Vision line using the node certificate |
| Hysteria 2 | `40000-50000/udp` | QUIC / UDP hopping | TLS + Salamander obfs | UDP-friendly high-throughput line |

---

## Architecture

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
│  ├─ 24443/tcp
│  │  └─ VLESS + REALITY + XHTTP
│  └─ 23333/tcp
│     └─ VLESS + TCP + TLS + Vision
│
└─ Hysteria 2
   └─ 40000-50000/udp
      └─ UDP port hopping
```

---

## Requirements

Recommended systems:

- Debian 11+
- Ubuntu 20.04+

Required on the server:

- root access
- Docker
- Docker Compose plugin
- `curl`
- `openssl`
- `python3`
- `ca-certificates`

If Docker is not installed yet:

```bash
curl -fsSL https://get.docker.com | bash
systemctl enable docker
systemctl start docker
docker compose version
```

---

## Cloudflare Token

Create a custom Cloudflare API token:

```text
My Profile
-> API Tokens
-> Create Token
-> Custom token
```

Recommended permissions:

| Permission | Purpose |
|---|---|
| `Zone - Zone - Read` | Find the matching Cloudflare zone automatically |
| `Zone - DNS - Edit` | Create, update, and delete A / AAAA records |

Recommended zone resource:

```text
Include - Specific zone - example.com
```

Use one token per root domain when possible. It is easier to audit and revoke later.

---

## Quick Start

The examples below use `jp1.example.com`.

### 1. Create Global Config

```bash
cat > /root/proxy-global.env <<'EOF'
EMAIL="you@example.com"
CF_TOKEN="your_cloudflare_api_token"

DEFAULT_XRAY_PORT="24443"
DEFAULT_XRAY_VISION_PORT="23333"
XRAY_RUN_UID="65532"
XRAY_RUN_GID="65532"
DEFAULT_HY2_PORT_RANGE="40000-50000"

ENABLE_IPV6="true"

REALITY_SNI_POOL="www.oracle.com,www.ibm.com,www.samsung.com,www.lg.com,developer.mozilla.org,source.android.com,www.intel.com,www.amd.com,www.lenovo.com,www.dell.com"
EOF

chmod 600 /root/proxy-global.env
```

You can also start from [examples/proxy-global.env.example](examples/proxy-global.env.example).

### 2. Download The Installer

```bash
wget -O /root/install-proxy-stack.sh --no-check-certificate \
  https://raw.githubusercontent.com/feng005211/simple-proxy-2-docker/main/install-proxy-stack.sh && \
chmod 700 /root/install-proxy-stack.sh
```

Or with `curl`:

```bash
curl -fsSL -o /root/install-proxy-stack.sh \
  https://raw.githubusercontent.com/feng005211/simple-proxy-2-docker/main/install-proxy-stack.sh && \
chmod 700 /root/install-proxy-stack.sh
```

### 3. Open Firewall Ports

Open these ports in your cloud security group:

```text
24443/tcp
23333/tcp
40000-50000/udp
```

If you use `ufw`:

```bash
ufw allow 24443/tcp
ufw allow 23333/tcp
ufw allow 40000:50000/udp
ufw status
```

### 4. Deploy

```bash
bash /root/install-proxy-stack.sh jp1.example.com
```

Equivalent full command:

```bash
bash /root/install-proxy-stack.sh jp1.example.com 24443 40000-50000 23333
```

Custom ports:

```bash
bash /root/install-proxy-stack.sh jp1.example.com 25443 41000-50000 23334
```

---

## Generated Files

For `jp1.example.com`, the default installation directory is:

```text
/opt/proxy-stack-jp1-example-com
```

Main files:

| Path | Description |
|---|---|
| `docker-compose.yml` | Xray and Hysteria 2 container definitions |
| `xray/config.json` | Xray server config |
| `hysteria/config.yaml` | Hysteria 2 server config |
| `certs/fullchain.pem` | acme.sh full certificate chain |
| `certs/privkey.pem` | acme.sh private key |
| `secrets.env` | UUIDs, REALITY keys, Hysteria passwords, and persisted node secrets |
| `client-info.txt` | VLESS REALITY/XHTTP URI, VLESS TCP/TLS Vision URI, and Hysteria 2 share URI |
| `clash-client-info.txt` | Mihomo / Clash Meta proxy snippet |
| `sing-box-client-info.json` | sing-box Hysteria 2 outbound snippet |
| `clients/hysteria2-client.yaml` | Official Hysteria 2 client config |

View client information:

```bash
cat /opt/proxy-stack-jp1-example-com/client-info.txt
```

---

## Command Reference

```bash
bash install-proxy-stack.sh <domain> [xray_tcp_port] [hysteria_udp_port_or_range] [xray_vision_tcp_port]
bash install-proxy-stack.sh cleanup <domain>
bash install-proxy-stack.sh uninstall <domain>
bash install-proxy-stack.sh purge <domain>
bash install-proxy-stack.sh bbr
bash install-proxy-stack.sh dd
```

Arguments:

| Argument | Required | Default | Description |
|---|---:|---|---|
| `domain` | yes | none | Node domain, for example `jp1.example.com` |
| `xray_tcp_port` | no | `24443` | VLESS REALITY/XHTTP TCP listen port |
| `hysteria_udp_port_or_range` | no | `40000-50000` | Hysteria 2 UDP port or hopping range |
| `xray_vision_tcp_port` | no | `23333` | VLESS TCP/TLS Vision listen port |

Important environment variables:

| Variable | Required | Default | Description |
|---|---:|---|---|
| `EMAIL` | yes | none | Email for acme.sh registration |
| `CF_TOKEN` | yes | none | Cloudflare API token |
| `DEFAULT_XRAY_PORT` | no | `24443` | Default VLESS REALITY/XHTTP TCP port |
| `DEFAULT_XRAY_VISION_PORT` | no | `23333` | Default VLESS TCP/TLS Vision TCP port |
| `XRAY_RUN_UID` | no | `65532` | Xray container UID and certificate key owner |
| `XRAY_RUN_GID` | no | `65532` | Xray container GID and certificate key group |
| `DEFAULT_HY2_PORT_RANGE` | no | `40000-50000` | Default Hysteria 2 UDP port or range |
| `ENABLE_IPV6` | no | `true` | Create AAAA records when IPv6 is detected |
| `PUBLIC_IPV4` | no | auto | Manually override detected IPv4 |
| `PUBLIC_IPV6` | no | auto | Manually override detected IPv6 |
| `INSTALL_DIR` | no | `/opt/proxy-stack-<domain>` | Custom installation directory |
| `MASQUERADE_URL` | no | `https://<domain>/` | Hysteria 2 masquerade proxy URL |
| `REALITY_SNI` | no | random choice | Fixed REALITY server name |
| `REALITY_TARGET` | no | `<REALITY_SNI>:443` | Fixed REALITY fallback target |
| `REALITY_SNI_POOL` | no | built in | Candidate list used when `REALITY_SNI` is omitted |

---

## Operations

Enter the installation directory:

```bash
cd /opt/proxy-stack-jp1-example-com
```

Check service status:

```bash
docker compose ps
```

View logs:

```bash
docker compose logs -f --tail=100
```

Only Xray:

```bash
docker compose logs -f --tail=100 xray
```

Only Hysteria 2:

```bash
docker compose logs -f --tail=100 hysteria
```

Upgrade images and restart:

```bash
docker compose pull
docker compose up -d
```

Restart services:

```bash
docker compose restart
```

---

## Cleanup

```bash
bash /root/install-proxy-stack.sh cleanup jp1.example.com
```

Aliases:

```bash
bash /root/install-proxy-stack.sh uninstall jp1.example.com
bash /root/install-proxy-stack.sh purge jp1.example.com
```

Cleanup will:

- Stop and remove Docker Compose services
- Delete the default `/opt/proxy-stack-*` installation directory
- Delete Cloudflare A / AAAA records for the node domain
- Remove the acme.sh ECC certificate directory for the node domain

If `CF_TOKEN` is not provided, Cloudflare DNS cleanup is skipped.

---

## Best Practices

- Use subdomains such as `jp1.example.com`, `sg1.example.com`, or `us1.example.com`.
- Keep Cloudflare records in DNS-only / gray-cloud mode.
- Do not deploy multiple VPS nodes with the same node domain.
- Open both cloud security group ports and system firewall ports.
- Confirm IPv6 inbound rules separately when using AAAA records.
- Keep `secrets.env`, `client-info.txt`, and generated client configs private.
- Pin Docker image versions before long-term production use if you need strict reproducibility.
- Re-running the installer reuses existing `secrets.env`; it does not rotate UUIDs or passwords unexpectedly.
- Only run `cleanup` before redeploying when you intentionally want old clients to stop working.

---

## Troubleshooting

### Docker Compose Is Missing

```bash
docker compose version
```

Install the Docker Compose plugin if the command is unavailable.

### Cloudflare DNS Update Fails

Check:

- `CF_TOKEN` is correct
- The token has `Zone Read` and `DNS Edit`
- The token is scoped to the current root domain
- The node domain is hosted on Cloudflare
- There is no same-name CNAME record

### IPv6 Does Not Work

```bash
ip -6 addr
curl -6 https://api64.ipify.org
```

If no usable IPv6 is detected, the script skips AAAA records and IPv4 deployment still works.

### Xray Cannot Read `/certs/privkey.pem`

The installer runs Xray with `XRAY_RUN_UID:XRAY_RUN_GID` and assigns the TLS key to that owner with `640` permissions. If you override the UID or GID, redeploy or fix ownership manually:

```bash
chown 65532:65532 /opt/proxy-stack-jp1-example-com/certs/fullchain.pem /opt/proxy-stack-jp1-example-com/certs/privkey.pem
chmod 644 /opt/proxy-stack-jp1-example-com/certs/fullchain.pem
chmod 640 /opt/proxy-stack-jp1-example-com/certs/privkey.pem
cd /opt/proxy-stack-jp1-example-com && docker compose restart xray
```

### Hysteria 2 Looks Like It Listens On Only One UDP Port

That is common with UDP port hopping. Hysteria 2 may directly listen on the first port while the rest of the range is handled through nftables / iptables rules.

### VLESS Client Cannot Connect

Compare your client with `client-info.txt`. For REALITY/XHTTP, check UUID, path, REALITY SNI, public key, short ID, fingerprint, and empty flow. For TCP/TLS Vision, check UUID, domain SNI, TCP transport, TLS, and `xtls-rprx-vision` flow.

---

## Project Files

| File | Description |
|---|---|
| `install-proxy-stack.sh` | Installer and cleanup script |
| `README.md` | English documentation |
| `README.zh.md` | Chinese documentation |
| `deploy.md` | Detailed Chinese deployment notes |
| `examples/proxy-global.env.example` | Example global environment file |
| `.gitattributes` | LF line endings for shell and Markdown files |

---

## Disclaimer

This project is intended for personal server administration, network connectivity testing, and access to your own devices and services. Follow local laws, cloud provider terms, and network service rules.
