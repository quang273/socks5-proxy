#!/bin/bash

# Nhập thông tin tự động qua echo -e
read -r INSTALL_MODE     # 1 = Cài SOCKS5
read -r CONFIG_MODE      # 2 = Thủ công
read -r ENABLE_TELEGRAM  # 1 = Gửi về Telegram
read -r BOT_TOKEN        # Bot Token
read -r USER_ID          # Telegram User ID
read -r PORT             # Port
read -r USERNAME         # Tên người dùng
read -r PASSWORD         # Mật khẩu

# Cài đặt Dante SOCKS5 server
apt update -y
apt install -y dante-server curl

# Lấy interface mạng chính
IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')

# Tạo cấu hình Dante
cat > /etc/danted.conf <<EOF
logoutput: /var/log/danted.log
internal: $IFACE port = $PORT
external: $IFACE

method: username none
user.notprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect error
}

pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    protocol: tcp udp
    method: username
    log: connect disconnect error
}
EOF

# Tạo user và thiết lập mật khẩu
useradd -M -s /bin/false "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd

# Khởi động lại dịch vụ Dante
systemctl restart danted
systemctl enable danted

# Lấy IP công khai
IP=$(curl -s ifconfig.me)

# Gửi thông tin proxy về Telegram
if [[ "$ENABLE_TELEGRAM" == "1" ]]; then
    PROXY_URL="socks5://$USERNAME:$PASSWORD@$IP:$PORT"
    MSG="🧦 SOCKS5 Proxy đã sẵn sàng:\n$PROXY_URL"
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$USER_ID" \
        -d text="$MSG"
fi
