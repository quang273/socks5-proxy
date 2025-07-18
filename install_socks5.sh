#!/bin/bash

# === Lấy metadata từ GCP ===
PROXY_USER=$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/attributes/PROXY_USER -H "Metadata-Flavor: Google")
PROXY_PASS=$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/attributes/PROXY_PASS -H "Metadata-Flavor: Google")
PROXY_PORT=$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/attributes/PROXY_PORT -H "Metadata-Flavor: Google")
BOT_TOKEN=$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/attributes/BOT_TOKEN -H "Metadata-Flavor: Google")
USER_ID=$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/attributes/USER_ID -H "Metadata-Flavor: Google")

# === Cài đặt dante-server ===
apt update -y && apt install -y dante-server curl

# === Cấu hình danted ===
cat > /etc/danted.conf <<EOF
logoutput: /var/log/danted.log
internal: 0.0.0.0 port = $PROXY_PORT
external: eth0
method: username none
user.notprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect error
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: connect
    log: connect disconnect error
}
EOF

# === Tạo user proxy ===
useradd -m $PROXY_USER
echo "$PROXY_USER:$PROXY_PASS" | chpasswd

# === Khởi động lại danted ===
systemctl restart danted

# === Gửi IP:PORT:USER:PASS về Telegram ===
PUBLIC_IP=$(curl -s ifconfig.me)
PROXY_INFO="$PUBLIC_IP:$PROXY_PORT:$PROXY_USER:$PROXY_PASS"
curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d "chat_id=${USER_ID}" \
    -d "text=${PROXY_INFO}"

# === In ra log kiểm tra ===
echo "Proxy SOCKS5 đã được cài đặt: $PROXY_INFO"
