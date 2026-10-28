#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 || "$#" -ne 2 ]]; then
  echo "Usage (as root): $0 add|disable <username>" >&2
  exit 2
fi

ACTION="$1"
USERNAME="$2"
[[ "$USERNAME" =~ ^vpn_[a-z][a-z0-9_-]{2,26}$ ]] || { echo "Username must start with vpn_" >&2; exit 2; }

case "$ACTION" in
  add)
    IFS= read -r PASSWORD
    [[ "${#PASSWORD}" -ge 12 && "$PASSWORD" != *:* ]] || { echo "Password must be at least 12 characters and contain no colon" >&2; exit 2; }
    if id "$USERNAME" >/dev/null 2>&1; then
      id -nG "$USERNAME" | grep -qw andeslogvpn || { echo "Existing user is not a VPN user" >&2; exit 1; }
    else
      useradd --no-create-home --gid andeslogvpn --shell /usr/sbin/nologin "$USERNAME"
    fi
    printf '%s:%s\n' "$USERNAME" "$PASSWORD" | chpasswd
    unset PASSWORD
    echo "VPN user $USERNAME enabled"
    ;;
  disable)
    id "$USERNAME" >/dev/null 2>&1 || { echo "User not found" >&2; exit 1; }
    passwd --lock "$USERNAME" >/dev/null
    systemctl restart openvpn-server@andeslog.service
    systemctl restart andeslog-openvpn-dns.service
    echo "VPN user $USERNAME disabled"
    ;;
  *) echo "Invalid action" >&2; exit 2 ;;
esac
