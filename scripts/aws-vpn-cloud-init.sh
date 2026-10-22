#!/bin/bash
set -euo pipefail
exec > >(tee -a /var/log/andeslog-vpn-bootstrap.log) 2>&1

export DEBIAN_FRONTEND=noninteractive
echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4
apt-get -o Acquire::ForceIPv4=true update -y
apt-get -o Acquire::ForceIPv4=true install -y wireguard iptables
cat > /etc/sysctl.d/99-andeslog-forwarding.conf <<'SYSCTL'
net.ipv4.ip_forward=1
SYSCTL
sysctl --system
install -d -o root -g root -m 0700 /etc/wireguard
echo "WireGuard is installed. Generate peer keys and configure wg0 through the documented post-deploy procedure." > /var/log/andeslog-vpn-setup.txt
