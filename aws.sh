#!/bin/bash

# Đọc từng dòng input theo thứ tự
read -r INSTALL_MODE      # 1 = Cài SOCKS5
read -r CONFIG_MODE       # 2 = Thủ công
read -r ENABLE_TELEGRAM   # 1 = Bật Telegram
read -r BOT_TOKEN         # Bot token
read -r USER_ID           # Telegram user ID
read -r PORT              # Port proxy
read -r USERNAME          # Tên đăng nhập proxy
read -r PASSWORD          # Mật khẩu proxy

# Cài đặt Dante SOCKS5
apt update -y
apt install -y dante-server curl -y

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

# Tạo tài khoản proxy
useradd -M -s /usr/sbin/nologin "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd

# Mở cổng nếu cần
iptables -I INPUT -p tcp --dport $PORT -j ACCEPT

# Khởi động dịch vụ
systemctl enable danted
systemctl restart danted

# Gửi Telegram nếu bật
if [ "$ENABLE_TELEGRAM" == "1" ]; then
    IP=$(curl -s ifconfig.me)
    PROXY_LINK="socks5://$USERNAME:$PASSWORD@$IP:$PORT"
    MESSAGE="🧦 SOCKS5 Proxy của bạn:\n$PROXY_LINK"
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
         -d chat_id="$USER_ID" \
         -d text="$MESSAGE"
fi
