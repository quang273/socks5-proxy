#!/bin/bash

# Đọc từng dòng input theo thứ tự
read -r INSTALL_MODE    # 1 = Cài SOCKS5
read -r CONFIG_MODE     # 2 = Thủ công
read -r ENABLE_TELEGRAM # 1 = Bật Telegram
read -r BOT_TOKEN       # Bot token
read -r USER_ID         # Telegram user ID
read -r PORT            # Port proxy
read -r USERNAME        # Tên đăng nhập proxy
read -r PASSWORD        # Mật khẩu proxy

# Cài đặt Dante SOCKS5
apt update -y
apt install -y dante-server curl

# Lấy interface mạng thật
IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')

# Tạo file cấu hình danted
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

# Tạo user
useradd -M -s /bin/false "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd

# Khởi động dịch vụ
systemctl restart danted
systemctl enable danted

# Lấy IP công khai
IP=$(curl -s ifconfig.me)

# Gửi thông tin Telegram (nếu bật)
if [[ "$ENABLE_TELEGRAM" == "1" ]]; then
    MSG="🧦 SOCKS5 Proxy đã sẵn sàng:\nsocks5://$USERNAME:$PASSWORD@$IP:$PORT"
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$USER_ID" \
        -d text="$MSG"
fi
