#!/bin/bash
# ======================== SOCKS5 PROXY CREATOR =========================
# Author : quang273 – 2025-06-26
# Usage  : setup_proxy_single_port PORT PASSWORD ALLOW_IP \
#                                ENABLE_TELEGRAM BOT_TOKEN USER_ID
# ======================================================================

install_dependencies() {
  command -v danted &>/dev/null && return
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y dante-server curl iptables
}

setup_proxy_single_port() {
  local PORT="$1" PASSWORD="$2" ALLOW_IP="$3"
  local ENABLE_TELEGRAM="$4" BOT_TOKEN="$5" USER_ID="$6"
  local USERNAME="quang"

  # 1) Validate PORT
  [[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT>1023 && PORT<65536)) || {
    echo "[ERR] Port $PORT không hợp lệ!" >&2; return 1; }

  # 2) Cài gói & user
  install_dependencies
  userdel -r "$USERNAME" 2>/dev/null || true
  useradd -M -s /usr/sbin/nologin "$USERNAME"
  echo "$USERNAME:$PASSWORD" | chpasswd

  # 3) Interface mặc định
  local IFACE
  IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')

  # 4) File cấu hình Dante
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

  # 5) Mở cổng & khởi động
  iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null \
    || iptables -A INPUT -p tcp --dport "$PORT" -j ACCEPT
  systemctl restart danted
  systemctl enable danted

  # 6) Thông tin proxy
  local IP
  IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
  local PROXY_LINE="$IP:$PORT:$USERNAME:$PASSWORD"

  # 7) Gửi Telegram nếu yêu cầu
  if [[ "$ENABLE_TELEGRAM" == "1" && -n "$BOT_TOKEN" && -n "$USER_ID" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
      -d chat_id="$USER_ID" \
      -d text="$PROXY_LINE" >/dev/null
  fi

  echo "[OK] Proxy SOCKS5 đã tạo: $PROXY_LINE"
}

# =========================== END FILE =================================
