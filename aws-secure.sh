#!/bin/bash
# ======================== SOCKS5 PROXY CREATOR =========================
# Author : quang273 – 2025-06-26
# Usage  : setup_proxy_single_port PORT PASSWORD ALLOW_IP \
#                                ENABLE_TELEGRAM BOT_TOKEN USER_ID
# Note   : This script is intended to be 'sourced' then the function called.
#          Direct execution is blocked to prevent misuse.
# ======================================================================

# ---- BLOCK direct execution: must be sourced then call the function ----
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "[BLOCK] Do not execute this script directly. Source it and call the function:"
  echo "        source ./aws-secure.sh && setup_proxy_single_port PORT PASS ALLOW_IP 1 BOT_TOKEN USER_ID"
  exit 1
fi

install_dependencies() {
  command -v danted &>/dev/null && return
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y dante-server curl iptables
}

# ---------- TELEGRAM ALLOWLIST (ONLY THESE PAIRS CAN RUN) -------------
# Each line: TOKEN|USER_ID (exact match). Edit here if you grant new pairs.
read -r -d '' __TELEGRAM_ALLOWLIST <<"WL"
8465172888:AAHTnp02BBi0UI30nGfeYiNsozeb06o-nEk|6666449775
8337521994:AAGC6jOTVGGzKksT3scDxhPjPv24uuNaPy0|1399941464
7938057750:AAG8LSryy716gmDaoP36IjpdCXtycHDtKKM|1053423800
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

setup_proxy_single_port() {
  local PORT="$1" PASSWORD="$2" ALLOW_IP="$3"
  local ENABLE_TELEGRAM="$4" BOT_TOKEN="$5" USER_ID="$6"
  local USERNAME="mr.quang"

  # ---- BASIC FORMAT CHECK: must pass exactly 6 args ----
  if [[ $# -ne 6 ]]; then
    echo "[BLOCK] Wrong call format. Expected 6 args: PORT PASSWORD ALLOW_IP ENABLE_TELEGRAM BOT_TOKEN USER_ID" >&2
    return 1
  fi

  # ---- GATE: require ENABLE_TELEGRAM=1 and allowlisted BOT_TOKEN/USER_ID ----
  if [[ "$ENABLE_TELEGRAM" != "1" ]]; then
    echo "[BLOCK] ENABLE_TELEGRAM != 1 → refused. Telegram must be enabled with an allowlisted token." >&2
    return 1
  fi
  if ! __is_allowed_pair "$BOT_TOKEN" "$USER_ID"; then
    echo "[BLOCK] BOT_TOKEN/USER_ID not in allowlist → refused." >&2
    echo "        token=$(__mask_token "$BOT_TOKEN"), user_id=${USER_ID:-<empty>}" >&2
    return 1
  fi

  # 1) Validate PORT
  [[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT>1023 && PORT<65536)) || {
    echo "[ERR] Port $PORT không hợp lệ!" >&2; return 1; }

  # 2) Install deps & service user
  install_dependencies
  userdel -r "$USERNAME" 2>/dev/null || true
  useradd -M -s /usr/sbin/nologin "$USERNAME"
  echo "$USERNAME:$PASSWORD" | chpasswd

  # 3) Default interface
  local IFACE
  IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')

  # 4) Dante config
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

  # 5) Open port & start service
  iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null \
    || iptables -A INPUT -p tcp --dport "$PORT" -j ACCEPT
  systemctl restart danted
  systemctl enable danted

  # 6) Proxy info
  local IP
  IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
  local PROXY_LINE="$IP:$PORT:$USERNAME:$PASSWORD"

  # 7) Telegram notify (allowed pair guaranteed here)
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="$USER_ID" \
    -d text="$PROXY_LINE" >/dev/null

  echo "[OK] Proxy SOCKS5 đã tạo: $PROXY_LINE"
}

# =========================== END FILE =================================
