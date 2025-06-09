#!/bin/bash

setup_proxy_single_port() {
  local PORT=$1
  local PASSWORD=$2
  local ALLOW_IP=$3
  local ENABLE_TELEGRAM=$4
  local BOT_TOKEN=$5
  local USER_ID=$6
  local USERNAME="quang"

  # Validate port, ip, token...
  # (bạn có thể giữ phần validate nếu muốn)

  # Cập nhật và cài đặt dante-server, curl, iptables
  apt update -y
  apt install -y dante-server curl iptables

  IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')

  # Viết file cấu hình dante
  cat > /etc/danted.conf <<EOF
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

  # Quản lý user
  userdel -r "$USERNAME" 2>/dev/null || true
  useradd -M -s /bin/false "$USERNAME"
  echo "$USERNAME:$PASSWORD" | chpasswd

  # Khởi động lại dịch vụ dante
  systemctl restart danted
  systemctl enable danted

  # Cấu hình iptables
  iptables -D INPUT -p tcp --dport "$PORT" ! -s "$ALLOW_IP" -j DROP 2>/dev/null || true
  iptables -D OUTPUT -p udp --dport 53 -j DROP 2>/dev/null || true
  iptables -A INPUT -p tcp --dport "$PORT" ! -s "$ALLOW_IP" -j DROP
  iptables -A OUTPUT -p udp --dport 53 -d 127.0.0.53 -j ACCEPT
  iptables -A OUTPUT -p udp --dport 53 -j DROP

  # Gửi tin nhắn Telegram chỉ có chuỗi base64
  IP=$(curl -s ifconfig.me)
  if [[ "$ENABLE_TELEGRAM" == "1" ]]; then
    PROXY="socks5://$USERNAME:$PASSWORD@$IP:$PORT"
    ENCODED=$(echo -n "$PROXY" | base64)
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
      -d chat_id="$USER_ID" \
      -d text="$ENCODED" \
      -d parse_mode="Markdown"
  fi
}
