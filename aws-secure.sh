#!/bin/bash
# =====================================================================
#  aws-secure.sh  ·  quang273  ·  2025-06-25
# ---------------------------------------------------------------------
#  Hàm public:
#      setup_proxy_single_port PORT PASSWORD ALLOW_IP \
#                              ENABLE_TELEGRAM BOT_TOKEN USER_ID
# ---------------------------------------------------------------------
#  • Cài Dante, mở firewall, tạo user “quang”.
#  • Gửi Telegram chuỗi  ip:port:quang:password  (không markdown).
#  • Ghi lại JSON phản hồi Telegram để dễ debug.
# =====================================================================

# ---------- 1. Cài gói cần thiết (một lần duy nhất) -------------------
install_dependencies() {
  command -v danted &>/dev/null && command -v jq &>/dev/null && return
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y dante-server curl iptables jq
}

# ---------- 2. Hàm khởi tạo proxy ------------------------------------
setup_proxy_single_port() {
  local PORT="$1" PASSWORD="$2" ALLOW_IP="$3"
  local ENABLE_TELEGRAM="$4" BOT_TOKEN="$5" USER_ID="$6"
  local USERNAME="quang"

  # 2.1 – Kiểm tra port hợp lệ
  if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1024 || PORT > 65535 )); then
    echo "[ERR]  Port $PORT không hợp lệ!" >&2
    return 1
  fi

  # 2.2 – Bảo đảm gói đã cài
  install_dependencies

  # 2.3 – Xác định interface mặc định
  local IFACE
  IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')

  # 2.4 – Ghi cấu hình Dante
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

  # 2.5 – Tạo / cập nhật user
  userdel -r "$USERNAME" 2>/dev/null || true
  useradd -M -s /bin/false "$USERNAME"
  echo "$USERNAME:$PASSWORD" | chpasswd

  # 2.6 – Khởi động Dante
  systemctl restart danted
  systemctl enable  danted

  # 2.7 – Mở cổng trên iptables (nếu chưa có)
  iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || \
  iptables -A INPUT -p tcp --dport "$PORT" -j ACCEPT

  # 2.8 – Gửi Telegram nếu được yêu cầu
  if [[ "$ENABLE_TELEGRAM" == "1" && -n "$BOT_TOKEN" && -n "$USER_ID" ]]; then
    local IP
    IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
    local PROXY_LINE="$IP:$PORT:$USERNAME:$PASSWORD"

    local TG_API="https://api.telegram.org/bot${BOT_TOKEN}/sendMessage"
    local RESPONSE
    RESPONSE=$(curl -s -d "chat_id=${USER_ID}" -d "text=${PROXY_LINE}" "${TG_API}")

    # Ghi phản hồi gọn gàng (nếu jq bị lỗi vẫn tiếp tục)
    echo "[TG]  $(echo "$RESPONSE" | jq -c '.' 2>/dev/null || echo "$RESPONSE")"
  fi

  echo "[OK]  Proxy $PORT đã sẵn sàng – user: $USERNAME"
}

# ============================ END FILE =================================
