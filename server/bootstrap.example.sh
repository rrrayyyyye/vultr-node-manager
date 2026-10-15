#!/bin/bash
# Vultr first-boot sing-box template. Replace all YOUR_* values before uploading.
# 凭据固定写死，所以每次重建机器客户端配置都不用改（只有 IP 变）
set -e

SB_VERSION="1.14.2"

# ---------- 0. 上报动态域名（DuckDNS）----------
# 客户端配置里填的是域名而不是 IP，所以重建机器换了 IP 也不用手工改配置。
# ip= 留空表示"用本机当前的公网 IP"，也就是这台机器的 IP。
DUCKDNS_DOMAIN="YOUR_DUCKDNS_SUBDOMAIN"
DUCKDNS_TOKEN="YOUR_DUCKDNS_TOKEN"
for i in $(seq 1 30); do
  RES=$(curl -s --max-time 10 "https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip=" || true)
  if [ "$RES" = "OK" ]; then
    echo "duckdns: reported $(hostname -I | awk '{print $1}')"
    break
  fi
  sleep 5
done

# ---------- 1. 安装 sing-box ----------
cd /tmp
curl -sL -o sb.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/sing-box-${SB_VERSION}-linux-amd64.tar.gz"
tar -xzf sb.tar.gz
install -m755 "sing-box-${SB_VERSION}-linux-amd64/sing-box" /usr/local/bin/sing-box

# ---------- 2. 写配置 ----------
mkdir -p /etc/sing-box
cat > /etc/sing-box/config.json <<'JSONEOF'
{
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
ufw allow 443/tcp
ufw allow 443/udp

echo "sing-box bootstrap done"
