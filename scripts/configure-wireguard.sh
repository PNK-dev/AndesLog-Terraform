#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

ROLE="${1:-}"
if [[ "$ROLE" != "aws" && "$ROLE" != "azure" ]]; then
  echo "Usage: $0 aws|azure [peer-public-key] [peer-public-ip]" >&2
  exit 2
fi

WG_DIR=/etc/wireguard
install -d -o root -g root -m 0700 "$WG_DIR"
if [[ ! -s "$WG_DIR/privatekey" ]]; then
  umask 077
  wg genkey > "$WG_DIR/privatekey"
  chmod 0600 "$WG_DIR/privatekey"
fi
LOCAL_PUBLIC_KEY="$(wg pubkey < "$WG_DIR/privatekey")"
echo "Public key for ${ROLE}: ${LOCAL_PUBLIC_KEY}"

if [[ "$#" -lt 3 ]]; then
  echo "Exchange this public key with the other VM, then rerun with: $0 ${ROLE} <peer-public-key> <peer-public-ip>"
  exit 0
fi

PEER_PUBLIC_KEY="$2"
PEER_PUBLIC_IP="$3"
if [[ ! "$PEER_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
  echo "Peer public key does not look like a WireGuard public key." >&2
  exit 2
fi
if [[ ! "$PEER_PUBLIC_IP" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "Peer public endpoint must be an IPv4 address or DNS name." >&2
  exit 2
fi

LOCAL_PRIVATE_KEY="$(cat "$WG_DIR/privatekey")"
if [[ "$ROLE" == "aws" ]]; then
  LOCAL_ADDRESS="172.30.50.1/30"
  PEER_ALLOWED_IPS="172.30.50.2/32,10.20.0.0/16"
  FORWARD_RULES=$(cat <<'RULES'
PostUp = iptables -C FORWARD -s 10.10.11.0/24 -d 10.20.0.0/16 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.10.11.0/24 -d 10.20.0.0/16 -j ACCEPT
PostUp = iptables -C FORWARD -s 10.10.12.0/24 -d 10.20.0.0/16 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.10.12.0/24 -d 10.20.0.0/16 -j ACCEPT
PostUp = iptables -C FORWARD -s 10.20.0.0/16 -d 10.10.11.0/24 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.20.0.0/16 -d 10.10.11.0/24 -j ACCEPT
PostUp = iptables -C FORWARD -s 10.20.0.0/16 -d 10.10.12.0/24 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.20.0.0/16 -d 10.10.12.0/24 -j ACCEPT
PostDown = iptables -D FORWARD -s 10.10.11.0/24 -d 10.20.0.0/16 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -s 10.10.12.0/24 -d 10.20.0.0/16 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -s 10.20.0.0/16 -d 10.10.11.0/24 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -s 10.20.0.0/16 -d 10.10.12.0/24 -j ACCEPT 2>/dev/null || true
RULES
)
else
  LOCAL_ADDRESS="172.30.50.2/30"
  PEER_ALLOWED_IPS="172.30.50.1/32,10.10.11.0/24,10.10.12.0/24"
  FORWARD_RULES=$(cat <<'RULES'
PostUp = iptables -C FORWARD -s 10.20.0.0/16 -d 10.10.11.0/24 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.20.0.0/16 -d 10.10.11.0/24 -j ACCEPT
PostUp = iptables -C FORWARD -s 10.20.0.0/16 -d 10.10.12.0/24 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.20.0.0/16 -d 10.10.12.0/24 -j ACCEPT
PostUp = iptables -C FORWARD -s 10.10.11.0/24 -d 10.20.0.0/16 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.10.11.0/24 -d 10.20.0.0/16 -j ACCEPT
PostUp = iptables -C FORWARD -s 10.10.12.0/24 -d 10.20.0.0/16 -j ACCEPT 2>/dev/null || iptables -A FORWARD -s 10.10.12.0/24 -d 10.20.0.0/16 -j ACCEPT
PostDown = iptables -D FORWARD -s 10.20.0.0/16 -d 10.10.11.0/24 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -s 10.20.0.0/16 -d 10.10.12.0/24 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -s 10.10.11.0/24 -d 10.20.0.0/16 -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -s 10.10.12.0/24 -d 10.20.0.0/16 -j ACCEPT 2>/dev/null || true
RULES
)
fi

cat > "$WG_DIR/wg0.conf" <<CONFIG
[Interface]
Address = ${LOCAL_ADDRESS}
ListenPort = 51820
PrivateKey = ${LOCAL_PRIVATE_KEY}
${FORWARD_RULES}

[Peer]
PublicKey = ${PEER_PUBLIC_KEY}
Endpoint = ${PEER_PUBLIC_IP}:51820
AllowedIPs = ${PEER_ALLOWED_IPS}
PersistentKeepalive = 25
CONFIG
chmod 0600 "$WG_DIR/wg0.conf"
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0
wg show wg0
