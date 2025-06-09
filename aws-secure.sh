#!/bin/bash

# Nhập biến từ stdin hoặc qua echo
read -r INSTALL_MODE CONFIG_MODE ENABLE_TELEGRAM BOT_TOKEN USER_ID PORT PASSWORD ALLOW_IP

# Sinh username ngẫu nhiên
USERNAME="user$(head /dev/urandom | tr -dc a-z0-9 | head -c6)"

# Cập nhật và cài đặt Dante SOCKS5
apt update -y && apt install -y dante-server curl iptables

# Lấy interface mạng chính
IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')

# Tạo file cấu hình cho Dante
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

# Xóa user cũ nếu có, sau đó tạo user mới
userdel -r "$USERNAME" 2>/dev/null || true
useradd -M -s /bin/false "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd

# Khởi động Dante
systemctl restart danted
systemctl enable danted

# Cấu hình iptables chỉ cho phép IP cụ thể truy cập, và chặn DNS leak
iptables -A INPUT -p tcp --dport $PORT ! -s $ALLOW_IP -j DROP
iptables -A OUTPUT -p udp --dport 53 -j DROP

# Lấy IP công khai
IP=$(curl -s ifconfig.me)

# Mã hóa proxy và gửi qua Telegram
if [[ "$ENABLE_TELEGRAM" == "1" ]]; then
    PROXY="socks5://$USERNAME:$PASSWORD@$IP:$PORT"
    ENCODED=$(echo -n "$PROXY" | base64)
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$USER_ID" \
        -d text="\xf0\x9f\x9a\x80 Proxy m\xe1\xbb\x9bi (base64): \`$ENCODED\`" \
        -d parse_mode="Markdown"
fi
