#!/bin/bash
# ======================== SOCKS5 PROXY CREATOR =========================
# Author : quang273 – 2025-10-25 (Clean & Extended version)
# Usage  : setup_proxy_single_port PORT PASSWORD ALLOW_IP ENABLE_TELEGRAM BOT_TOKEN USER_ID PROXY_USERNAME
# ======================================================================

set -euo pipefail

install_dependencies() {
  command -v danted &>/dev/null && return
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl iptables
  apt-get install -y dante-server || apt-get install -y danted || true
}

# ---------- TELEGRAM ALLOWLIST (TOKEN|USER_ID) -------------------------
read -r -d '' __TELEGRAM_ALLOWLIST <<"WL" || true
8465172888:AAHTnp02BBi0UI30nGfeYiNsozeb06o-nEk|6666449775
8337521994:AAGC6jOTVGGzKksT3scDxhPjPv24uuNaPy0|1399941464
7938057750:AAG8LSryy716gmDaoP36IjpdCXtycHDtKKM|1053423800
8333633082:AAHd0udd0eJbLt_iKXRaaYYWznPjx7QEB-8|8246321275
8335425461:AAF0umwP0lcGclhOK3ZDMAtj489-V7ffdaw|8001423953
8044621096:AAG24BkC1EquTQWRzU0yITE5vyfpL65k3N4|6483851447
8457121857:AAGlY7uy4oGBn-I_3-mlrUZLy17OSF9rUU0|8111988352
7944651217:AAH-7bpIS-X7w2prt1iN3mPeh88m4favJKI|7490814886
7959947367:AAGz46hZFXQ_n4puvHiOcL2mVVb6mFfmzGM|891365260
WL

__mask_token() {
  local t="${1:-}"
  [[ -z "$t" ]] && { echo "<empty>"; return; }
  echo "${t:0:8}********"
}

__is_allowed_pair() {
  local token="${1:-}" uid="${2:-}"
  [[ -z "$token" || -z "$uid" ]] && return 1
  local pair="$token|$uid"
  grep -qxF -- "$pair" <<<"$__TELEGRAM_ALLOWLIST"
}

enable_secure_network() {
  echo "[INFO] Bật IP forwarding và cấu hình iptables an toàn..."
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  grep -q 'net.ipv4.ip_forward=1' /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  iptables -P INPUT ACCEPT
  iptables -P FORWARD ACCEPT
  iptables -P OUTPUT ACCEPT
  iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A INPUT -i lo -j ACCEPT
  iptables -A INPUT -p icmp -j ACCEPT
  iptables-save > /etc/iptables.rules
  cat >/etc/network/if-pre-up.d/iptablesload <<'EOF'
#!/bin/sh
iptables-restore < /etc/iptables.rules
EOF
  chmod +x /etc/network/if-pre-up.d/iptablesload
}

setup_proxy_single_port() {
  local PORT="$1" PASSWORD="$2" ALLOW_IP="$3"
  local ENABLE_TELEGRAM="$4" BOT_TOKEN="$5" USER_ID="$6"
  local PROXY_USERNAME_ARG="${7:-}"
  local USERNAME="${PROXY_USERNAME_ARG:-mr.quang}"

  if [[ "$ENABLE_TELEGRAM" != "1" ]]; then
    echo "[BLOCK] ENABLE_TELEGRAM != 1 → từ chối chạy." >&2
    return 1
  fi
  if ! __is_allowed_pair "$BOT_TOKEN" "$USER_ID"; then
    echo "[BLOCK] BOT_TOKEN/USER_ID không nằm trong whitelist → từ chối chạy." >&2
    echo "        token=$(__mask_token "$BOT_TOKEN"), user_id=${USER_ID:-<empty>}" >&2
    return 1
  fi

  [[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT>1023 && PORT<65536)) || {
    echo "[ERR] Port $PORT không hợp lệ!" >&2; return 1; }

  install_dependencies
  enable_secure_network

  userdel -r "$USERNAME" 2>/dev/null || true
  useradd -M -s /usr/sbin/nologin "$USERNAME"
  echo "$USERNAME:$PASSWORD" | chpasswd

  local IFACE
  IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')

  touch /var/log/danted.log && chmod 666 /var/log/danted.log

  cat >/etc/danted.conf <<EOF
logoutput: /var/log/danted.log
internal: $IFACE port = $PORT
external: $IFACE
method: username
user.notprivileged: nobody
client pass { from: $ALLOW_IP to: 0.0.0.0/0 }
pass {
  from: $ALLOW_IP to: 0.0.0.0/0
  protocol: tcp udp
  method: username
}
EOF

  iptables -D INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true
  iptables -A INPUT -p tcp --dport "$PORT" -j ACCEPT

  systemctl stop danted 2>/dev/null || true

  local IP
  IP=$(curl -s ifconfig.me || curl -s ipv4.icanhazip.com || hostname -I | awk '{print $1}')
  local PROXY_LINE="$IP:$PORT:$USERNAME:$PASSWORD"

  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="$USER_ID" \
    -d text="[INIT] $PROXY_LINE" >/dev/null || true

  cat >/etc/proxy_notify.env <<EOF
BOT_TOKEN="$BOT_TOKEN"
USER_ID="$USER_ID"
PROXY_PORT="$PORT"
PROXY_USER="$USERNAME"
PROXY_PASS="$PASSWORD"
EOF
  chmod 0600 /etc/proxy_notify.env

  cat >/usr/local/bin/proxy-notify.sh <<'EOS'
#!/bin/bash
set -euo pipefail
: "${BOT_TOKEN:?}"; : "${USER_ID:?}"
: "${PROXY_PORT:?}"; : "${PROXY_USER:?}"; : "${PROXY_PASS:?}"
action="${1:-start}"
if [[ "$action" == "start" && "${NOTIFY_MANUAL:-0}" != "1" ]]; then
    exit 0
fi
IP="$(curl -s ifconfig.me || curl -s ipv4.icanhazip.com || hostname -I | awk '{print $1}')"
PROXY_LINE="${IP}:${PROXY_PORT}:${PROXY_USER}:${PROXY_PASS}"
case "$action" in
  start) prefix="NEW" ;;
  stop)  prefix="STOPPED" ;;
  *)     prefix="INFO" ;;
esac
curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  -d chat_id="$USER_ID" \
  --data-urlencode "text=[${prefix}] ${PROXY_LINE} ($(date +'%H:%M:%S %d-%m-%Y'))" >/dev/null || true
EOS
  chmod 0755 /usr/local/bin/proxy-notify.sh

  install -d -m 0755 /etc/systemd/system/danted.service.d
  cat >/etc/systemd/system/danted.service.d/notify.conf <<'EOF'
[Service]
EnvironmentFile=/etc/proxy_notify.env
Environment=NOTIFY_MANUAL=0
ExecStartPost=/usr/local/bin/proxy-notify.sh start
ExecStopPost=/usr/local/bin/proxy-notify.sh stop
EOF

  systemctl daemon-reload
  systemctl restart danted
  systemctl enable danted

  echo "[OK] Proxy SOCKS5 đã tạo: $PROXY_LINE"
  echo "[INFO] IP forwarding và iptables đã được bật tự động."
}

# =========================== END FILE =================================
