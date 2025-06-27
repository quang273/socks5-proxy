#!/bin/bash
# =====================================================
#  aws-secure.sh  –  quang273 / 2025-06-25
#  Hàm: setup_proxy_single_port PORT PASSWORD ALLOW_IP \
#                               ENABLE_TELEGRAM BOT_TOKEN USER_ID
# =====================================================

# ---------- 1. Cài gói cần thiết (một lần) ------------
install_dependencies() {
  # Kiểm tra nếu danted đã cài đặt thì thoát sớm
  command -v danted &>/dev/null && return

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y dante-server curl iptables
}

# ---------- 2. Hàm khởi tạo proxy --------------------
setup_proxy_single_port() {
  local PORT="$1" PASSWORD="$2" ALLOW_IP="$3"
  local ENABLE_TELEGRAM="$4" BOT_TOKEN="$5" USER_ID="$6"
  local USERNAME="quang" # Tên người dùng mặc định cho proxy

  # 2.1 Kiểm tra port hợp lệ
  if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1024 || PORT > 65535 )); then
    echo "[ERR]  Port $PORT không hợp lệ! Vui lòng chọn port từ 1024 đến 65535." >&2
    return 1
  fi

  # 2.2 Cài gói cần thiết
  echo "[INFO] Đang cài đặt các gói cần thiết..."
  install_dependencies

  # 2.3 Lấy interface mặc định
  local IFACE
  IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
  if [[ -z "$IFACE" ]]; then
    echo "[ERR] Không thể tìm thấy interface mạng mặc định." >&2
    return 1
  fi
  echo "[INFO] Interface mạng được phát hiện: $IFACE"

  # 2.4 Tạo cấu hình Dante
  echo "[INFO] Tạo cấu hình Dante tại /etc/danted.conf..."
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

  # 2.5 Tạo tài khoản proxy
  echo "[INFO] Tạo tài khoản proxy: $USERNAME..."
  userdel -r "$USERNAME" 2>/dev/null || true # Xóa người dùng cũ nếu tồn tại
  useradd -M -s /bin/false "$USERNAME"       # Tạo người dùng mới không có thư mục home và shell
  echo "$USERNAME:$PASSWORD" | chpasswd      # Đặt mật khẩu

  # 2.6 Khởi động dịch vụ Dante
  echo "[INFO] Khởi động và kích hoạt dịch vụ danted..."
  systemctl restart danted
  systemctl enable danted
  if ! systemctl is-active --quiet danted; then
    echo "[ERR] Dịch vụ Dante không thể khởi động. Vui lòng kiểm tra log." >&2
    return 1
  fi

  # 2.7 Mở cổng trên firewall (iptables)
  echo "[INFO] Mở cổng $PORT trên firewall (iptables)..."
  iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || \
  iptables -A INPUT -p tcp --dport "$PORT" -j ACCEPT
  # Lưu các quy tắc iptables để chúng tồn tại sau khi reboot (cần gói iptables-persistent)
  # Nếu bạn không có iptables-persistent, các quy tắc này sẽ mất sau khi khởi động lại.
  # apt-get install -y iptables-persistent
  # netfilter-persistent save

  # 2.8 Gửi thông tin proxy về Telegram (nếu bật)
  if [[ "$ENABLE_TELEGRAM" == "1" && -n "$BOT_TOKEN" && -n "$USER_ID" ]]; then
    echo "[INFO] Đang cố gắng gửi thông tin proxy về Telegram..."
    local IP
    # Thử 2 cách lấy IP công cộng
    IP=$(curl -s ifconfig.me 2>/dev/null || true)
    [[ -z "$IP" ]] && IP=$(hostname -I | awk '{print $1}') # Lấy IP nội bộ nếu ifconfig.me thất bại

    if [[ -z "$IP" ]]; then
      echo "[WARN] Không thể lấy địa chỉ IP công cộng. Proxy có thể không hoạt động như mong đợi." >&2
      echo "[WARN] Không gửi được thông tin Telegram vì không có IP." >&2
    else
      local PROXY_LINE="$IP:$PORT:$USERNAME:$PASSWORD"
      local TELEGRAM_API_URL="https://api.telegram.org/bot$BOT_TOKEN/sendMessage"

      # Gửi tin nhắn đơn giản không dùng Markdown block
      curl -s -X POST "$TELEGRAM_API_URL" \
           -d chat_id="$USER_ID" \
           -d text="$PROXY_LINE"

      if [ $? -ne 0 ]; then
        echo "[ERR] Lỗi khi gửi tin nhắn Telegram. Kiểm tra BOT_TOKEN, USER_ID hoặc kết nối mạng." >&2
      else
        echo "[OK] Thông tin proxy đã được gửi về Telegram."
      fi
    fi
  else
    echo "[INFO] Gửi thông tin Telegram bị vô hiệu hóa hoặc thiếu BOT_TOKEN/USER_ID."
  fi

  echo "[OK] Proxy Socks5 đã được thiết lập thành công trên port $PORT."
  echo "     Địa chỉ Proxy: $([[ -n "$IP" ]] && echo "$IP" || echo "Không xác định")"
  echo "     Port: $PORT"
  echo "     Username: $USERNAME"
  echo "     Password: $PASSWORD"
}

# ====================== Hết file ======================
