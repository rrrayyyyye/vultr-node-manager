#!/bin/bash
# Vultr first-boot sing-box template. Replace all YOUR_* values before uploading.
# 凭据固定写死，所以每次重建机器客户端配置都不用改（只有 IP 变）
set -euo pipefail
umask 077

SB_VERSION="1.14.2"
IP_VERSION="ipv4"

# IPv6-only: DNS64/NAT64 provides access to IPv4-only download hosts.
# This optional public service is documented at https://nat64.net/.
DNS_SETTINGS=""
if [ "$IP_VERSION" = "ipv6" ]; then
  # Debian minimal images do not necessarily include resolved, curl or UFW.
  # Seed DNS first so apt itself can work over an IPv6-only connection.
  if ! command -v resolvectl >/dev/null 2>&1; then
    if [ ! -e /etc/resolv.conf.node-original ]; then
      cp -L /etc/resolv.conf /etc/resolv.conf.node-original
    fi
    printf 'nameserver 2a01:4f9:c010:3f02::1\nnameserver 2a00:1098:2b::1\n' > /etc/resolv.conf
    chmod 644 /etc/resolv.conf
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o Acquire::ForceIPv6=true -o Acquire::Retries=3 update
    apt-get -o Acquire::ForceIPv6=true -o Acquire::Retries=3 install -y --no-install-recommends systemd-resolved curl ca-certificates
  fi
  install -d -m755 /etc/systemd/resolved.conf.d
  cat > /etc/systemd/resolved.conf.d/90-node-dns64.conf <<'DNSEOF'
[Resolve]
DNS=2a01:4f9:c010:3f02::1 2a00:1098:2b::1 2a01:4f8:c2c:123f::1
Domains=~.
DNSEOF
  chmod 644 /etc/systemd/resolved.conf.d/90-node-dns64.conf
  systemctl enable --now systemd-resolved
  systemctl restart systemd-resolved
  DNS_SETTINGS='"dns":{"servers":[{"type":"udp","tag":"dns64","server":"2a01:4f9:c010:3f02::1"}],"strategy":"ipv6_only"},"route":{"default_domain_resolver":{"server":"dns64","strategy":"ipv6_only"}},'
fi

if ! command -v curl >/dev/null 2>&1 || [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o Acquire::Retries=3 update
  apt-get -o Acquire::Retries=3 install -y --no-install-recommends curl ca-certificates
fi

# ---------- 0. 上报动态域名（DuckDNS）----------
# 客户端配置里填的是域名而不是 IP，所以重建机器换了 IP 也不用手工改配置。
# ip= 留空表示"用本机当前的公网 IP"，也就是这台机器的 IP。
DUCKDNS_DOMAIN="YOUR_DUCKDNS_SUBDOMAIN"
DUCKDNS_TOKEN="YOUR_DUCKDNS_TOKEN"
DNS_OK=false
for i in $(seq 1 30); do
  if [ "$IP_VERSION" = "ipv6" ]; then
    # Use the address actually chosen by the default IPv6 route.
    NODE_IPV6=$(ip -6 route get 2606:4700:4700::1111 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || true)
    if [ -z "$NODE_IPV6" ]; then sleep 5; continue; fi
    RES=$(curl -6 -fsS --max-time 15 --get 'https://www.duckdns.org/update' --data-urlencode "domains=${DUCKDNS_DOMAIN}" --data-urlencode "token=${DUCKDNS_TOKEN}" --data-urlencode "ipv6=${NODE_IPV6}" || true)
  else
    RES=$(curl -fsS --max-time 15 "https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip=" || true)
  fi
  if [ "$RES" = "OK" ]; then
    echo "duckdns: reported $(hostname -I | awk '{print $1}')"
    DNS_OK=true
    break
  fi
  sleep 5
done
if [ "$DNS_OK" != true ]; then echo 'DuckDNS update failed' >&2; exit 1; fi

# ---------- 1. 安装 sing-box ----------
cd /tmp
curl -fSL --retry 3 --connect-timeout 15 --max-time 240 -o sb.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/sing-box-${SB_VERSION}-linux-amd64.tar.gz"
echo 'a684484d7477d1437282ee411f4d131d0340aaad60a7868841ebd5d87dd8a0c6  sb.tar.gz' | sha256sum -c -
tar -xzf sb.tar.gz
install -m755 "sing-box-${SB_VERSION}-linux-amd64/sing-box" /usr/local/bin/sing-box

# ---------- 2. 写配置 ----------
mkdir -p /etc/sing-box
cat > /etc/sing-box/config.json <<JSONEOF
{
  ${DNS_SETTINGS}
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": 443,
      "users": [
        { "uuid": "YOUR_VLESS_UUID", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.microsoft.com",
        "reality": {
          "enabled": true,
          "handshake": { "server": "www.microsoft.com", "server_port": 443 },
          "private_key": "YOUR_REALITY_PRIVATE_KEY",
          "short_id": ["YOUR_REALITY_SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct" } ]
}
JSONEOF
chmod 600 /etc/sing-box/config.json
/usr/local/bin/sing-box check -c /etc/sing-box/config.json

# ---------- 3. systemd 服务 ----------
cat > /etc/systemd/system/sing-box.service <<'UNITEOF'
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
UNITEOF

systemctl daemon-reload
systemctl enable sing-box --now

# ---------- 4. 防火墙放行 443（上次就是漏了这一步）----------
if command -v ufw >/dev/null 2>&1; then
  ufw allow 443/tcp
  ufw allow 443/udp
fi

echo "sing-box bootstrap done"
