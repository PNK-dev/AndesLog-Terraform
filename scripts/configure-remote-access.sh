#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 || "$#" -ne 3 ]]; then
  echo "Usage (as root): $0 <files-account> <files-private-ip> <vpn-public-ip>" >&2
  exit 2
fi

FILES_ACCOUNT="$1"
FILES_IP="$2"
PUBLIC_IP="$3"
[[ "$FILES_ACCOUNT" =~ ^[a-z0-9]{3,24}$ ]] || exit 2
[[ "$FILES_IP" =~ ^10\.20\.11\.[0-9]{1,3}$ ]] || exit 2
[[ "$PUBLIC_IP" =~ ^[0-9.]+$ ]] || exit 2

if ! command -v openvpn >/dev/null 2>&1 || ! command -v dnsmasq >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq openvpn openssl dnsmasq-base iptables
fi

FILES_FQDN="$FILES_ACCOUNT.file.core.windows.net"
FILES_READY=0
for attempt in {1..24}; do
  RESOLVED_IP="$(getent ahostsv4 "$FILES_FQDN" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
  if [[ "$RESOLVED_IP" == "$FILES_IP" ]] && timeout 3 bash -c "</dev/tcp/$FILES_FQDN/445" 2>/dev/null; then
    FILES_READY=1
    break
  fi
  sleep 5
done
[[ "$FILES_READY" -eq 1 ]] || { echo "Azure Files private endpoint did not resolve and answer on TCP 445" >&2; exit 1; }

BASE=/etc/openvpn/andeslog
install -d -o root -g root -m 0700 "$BASE"
install -d -o root -g root -m 0755 /etc/openvpn/server

if [[ ! -s "$BASE/ca.crt" ]]; then
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 \
    -subj '/CN=AndesLog Remote VPN CA' -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout "$BASE/ca.key" -out "$BASE/ca.crt"
fi
if [[ ! -s "$BASE/server.crt" ]]; then
  openssl req -newkey rsa:3072 -sha256 -nodes \
    -subj '/CN=andeslog-vpn' -keyout "$BASE/server.key" -out "$BASE/server.csr"
  cat > "$BASE/server.ext" <<'EOF'
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:andeslog-vpn
EOF
  openssl x509 -req -in "$BASE/server.csr" -CA "$BASE/ca.crt" -CAkey "$BASE/ca.key" \
    -CAcreateserial -out "$BASE/server.crt" -days 825 -sha256 -extfile "$BASE/server.ext"
fi
if [[ ! -s "$BASE/tls-crypt.key" ]]; then
  openvpn --genkey tls-crypt "$BASE/tls-crypt.key"
fi
chmod 0600 "$BASE/ca.key" "$BASE/server.key" "$BASE/tls-crypt.key"
chmod 0644 "$BASE/ca.crt" "$BASE/server.crt"

groupadd --force andeslogvpn
cat > /etc/pam.d/andeslog-openvpn <<'EOF'
auth required pam_succeed_if.so quiet user ingroup andeslogvpn
@include common-auth
@include common-account
EOF

PLUGIN=/usr/lib/openvpn/openvpn-plugin-auth-pam.so
if [[ ! -f "$PLUGIN" ]]; then
  PLUGIN=/usr/lib/x86_64-linux-gnu/openvpn/plugins/openvpn-plugin-auth-pam.so
fi
[[ -f "$PLUGIN" ]] || { echo "OpenVPN PAM plugin not found" >&2; exit 1; }

cat > /etc/openvpn/server/andeslog.conf <<EOF
port 1194
proto udp
dev tun1
topology subnet
server 172.30.60.0 255.255.255.0
push "route 10.20.11.0 255.255.255.0"
push "dhcp-option DNS 172.30.60.1"
ca $BASE/ca.crt
cert $BASE/server.crt
key $BASE/server.key
tls-crypt $BASE/tls-crypt.key
dh none
tls-version-min 1.2
data-ciphers AES-256-GCM:AES-128-GCM
auth SHA256
verify-client-cert none
username-as-common-name
plugin $PLUGIN andeslog-openvpn
keepalive 10 120
persist-key
persist-tun
status /run/andeslog-openvpn-status.log
verb 3
EOF
chmod 0600 /etc/openvpn/server/andeslog.conf

cat > "$BASE/dnsmasq.conf" <<'EOF'
interface=tun1
bind-interfaces
listen-address=172.30.60.1
no-resolv
server=168.63.129.16
user=nobody
group=nogroup
EOF
dnsmasq --test --conf-file="$BASE/dnsmasq.conf"
cat > /etc/systemd/system/andeslog-openvpn-dns.service <<EOF
[Unit]
Description=AndesLog DNS forwarder for remote VPN clients
Requires=openvpn-server@andeslog.service
After=openvpn-server@andeslog.service

[Service]
Type=simple
ExecStart=/usr/sbin/dnsmasq --keep-in-foreground --conf-file=$BASE/dnsmasq.conf --pid-file=
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

cat > /usr/local/sbin/andeslog-openvpn-firewall <<EOF
#!/usr/bin/env bash
set -euo pipefail
iptables -N ANDESLOG_OVPN 2>/dev/null || true
iptables -F ANDESLOG_OVPN
iptables -C FORWARD -s 172.30.60.0/24 -j ANDESLOG_OVPN 2>/dev/null || iptables -I FORWARD 1 -s 172.30.60.0/24 -j ANDESLOG_OVPN
iptables -A ANDESLOG_OVPN -d $FILES_IP/32 -p tcp --dport 445 -j ACCEPT
iptables -A ANDESLOG_OVPN -j DROP
iptables -t nat -N ANDESLOG_OVPN_NAT 2>/dev/null || true
iptables -t nat -F ANDESLOG_OVPN_NAT
iptables -t nat -C POSTROUTING -s 172.30.60.0/24 -j ANDESLOG_OVPN_NAT 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s 172.30.60.0/24 -j ANDESLOG_OVPN_NAT
iptables -t nat -A ANDESLOG_OVPN_NAT -d $FILES_IP/32 -p tcp --dport 445 -j MASQUERADE
EOF
chmod 0750 /usr/local/sbin/andeslog-openvpn-firewall
cat > /etc/systemd/system/andeslog-openvpn-firewall.service <<'EOF'
[Unit]
Description=AndesLog remote VPN firewall rules
After=network-online.target
Before=openvpn-server@andeslog.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/andeslog-openvpn-firewall
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now andeslog-openvpn-firewall.service
systemctl enable openvpn-server@andeslog.service
systemctl restart openvpn-server@andeslog.service
systemctl is-active --quiet openvpn-server@andeslog.service
systemctl enable andeslog-openvpn-dns.service
systemctl restart andeslog-openvpn-dns.service
systemctl is-active --quiet andeslog-openvpn-dns.service

cat > "$BASE/andeslog-windows.ovpn" <<EOF
client
dev tun
proto udp
remote $PUBLIC_IP 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verify-x509-name andeslog-vpn name
setenv CLIENT_CERT 0
auth-user-pass
auth-nocache
tls-version-min 1.2
data-ciphers AES-256-GCM:AES-128-GCM
verb 3
<ca>
$(cat "$BASE/ca.crt")
</ca>
<tls-crypt>
$(cat "$BASE/tls-crypt.key")
</tls-crypt>
EOF
chmod 0600 "$BASE/andeslog-windows.ovpn"

echo "OpenVPN ready for account $FILES_ACCOUNT; profile at $BASE/andeslog-windows.ovpn"
