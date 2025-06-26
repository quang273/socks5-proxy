#!/bin/bash

# =====================================================

#  aws-secure.sh  –  quang273 / 2025-06-25

#  Hàm: setup_proxy_single_port PORT PASSWORD ALLOW_IP \

#                               ENABLE_TELEGRAM BOT_TOKEN USER_ID

# =====================================================



# ---------- 1. Cài gói cần thiết (một lần) ------------#!/bin/bash
# ==================== SCRIPT TẠO SOCKS5 PROXY ======================
# 🛡️ Tác giả: Quang273 - 2025
# 📦 Cài Dante, tạo proxy, gửi thông báo về Telegram
# ===============================================================

setup_proxy_single_port() {
  local PORT="$1"
  local PASSWORD="$2"
  local ALLOW_IP="$3"
  local ENABLE_TELEGRAM="$4"
  local BOT_TOKEN="$5"
  local USER_ID="$6"
  local USERNAME="quang"

  # ✅ Cài đặt gói cần thiết
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y dante-server curl iptables

  # ✅ Tạo user SOCKS
  userdel -r "$USERNAME" 2>/dev/null || true
  useradd -M -s /usr/sbin/nologin "$USERNAME"
  echo "$USERNAME:$PASSWORD" | chpasswd

  # ✅ Xác định interface mạng
  local IFACE
  IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')

  # ✅ Ghi file cấu hình Dante
  cat >/etc/danted.conf <<EOF
logoutput: /var/log/danted.log

internal: $IFACE port = $PORT
external: $IFACE

method: username
user.notprivileged: nobody

client pass {
  from: $ALLOW_IP to: 0.0.0.0/0
  log: connect disconnect error
}

pass {
  from: $ALLOW_IP to: 0.0.0.0/0
  protocol: tcp udp
  method: username
  log: connect disconnect error
}
EOF

  # ✅ Mở cổng trên firewall
  iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null \
    || iptables -A INPUT -p tcp --dport "$PORT" -j ACCEPT

  # ✅ Restart dịch vụ
  systemctl restart danted
  systemctl enable danted

  # ✅ Lấy IP public
  local IP
  IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
  local PROXY_LINE="$IP:$PORT:$USERNAME:$PASSWORD"
  local PROXY_URI="socks5://$USERNAME:$PASSWORD@$IP:$PORT"
  local ENCODED=$(echo -n "$PROXY_URI" | base64)

  # ✅ Gửi Telegram nếu bật
  if [[ "$ENABLE_TELEGRAM" == "1" && -n "$BOT_TOKEN" && -n "$USER_ID" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
      -d chat_id="$USER_ID" \
      -d parse_mode="Markdown" \
      -d text="🎉 *Proxy đã sẵn sàng*\n\n*Base64 (cho tool tự động)*\n\`\`\`\n$ENCODED\n\`\`\`\n*Dòng thuần (ip:port:user:pass)*\n\`\`\`\n$PROXY_LINE\n\`\`\`" >/dev/null
  fi

  echo "[✔] Proxy SOCKS5 đã tạo: $PROXY_LINE"
}


install_dependencies() {

  command -v danted &>/dev/null && return

  export DEBIAN_FRONTEND=noninteractive

  apt-get update -y

  apt-get install -y dante-server curl iptables

}



# ---------- 2. Hàm khởi tạo proxy --------------------

setup_proxy_single_port() {

  local PORT="$1" PASSWORD="$2" ALLOW_IP="$3"

  local ENABLE_TELEGRAM="$4" BOT_TOKEN="$5" USER_ID="$6"

  local USERNAME="quang"



  # 2.1 Kiểm tra port hợp lệ

  if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1024 || PORT > 65535 )); then

    echo "[ERR]  Port $PORT không hợp lệ!" >&2

    return 1

  fi



  # 2.2 Cài gói

  install_dependencies



  # 2.3 Lấy interface mặc định

  local IFACE

  IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')



  # 2.4 Tạo cấu hình Dante

  cat >/etc/danted.conf <<EOF

internal: $IFACE port = $PORT

external: $IFACE



method: username

user.notprivileged: nobody



client pass {

  from: $ALLOW_IP to: 0.0.0.0/0

}



pass {

  from: $ALLOW_IP to: 0.0.0.0/0

  protocol: tcp udp

  method: username

}

EOF



  # 2.5 Tài khoản proxy

  userdel -r "$USERNAME" 2>/dev/null || true

  useradd -M -s /bin/false "$USERNAME"

  echo "$USERNAME:$PASSWORD" | chpasswd



  # 2.6 Khởi động dịch vụ

  systemctl restart danted

  systemctl enable  danted



  # 2.7 Mở cổng trên firewall (nếu chưa mở)

  iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || \

  iptables -A INPUT -p tcp --dport "$PORT" -j ACCEPT



  # 2.8 Gửi Telegram (nếu bật)

  if [[ "$ENABLE_TELEGRAM" == "1" && -n "$BOT_TOKEN" && -n "$USER_ID" ]]; then

    local IP

    # Thử 2 cách lấy IP

    IP=$(curl -s ifconfig.me 2>/dev/null || true)

    [[ -z "$IP" ]] && IP=$(hostname -I | awk '{print $1}')

    local PROXY_LINE="$IP:$PORT:$USERNAME:$PASSWORD"

    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \

         -d chat_id="$USER_ID" \

         -d parse_mode="Markdown" \

         -d text="\`\`\`\n$PROXY_LINE\n\`\`\`"

  fi



  echo "[OK]  Proxy chạy trên $PORT – user: $USERNAME"

}



# ====================== Hết file ======================
