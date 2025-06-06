#!/bin/bash

read -r INSTALL_MODE
read -r CONFIG_MODE
read -r ENABLE_TELEGRAM
read -r BOT_TOKEN
read -r USER_ID
read -r PORT
read -r USERNAME
read -r PASSWORD

apt update -y
apt install -y dante-server curl

IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')

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

useradd -M -s /bin/false "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd

systemctl restart danted
systemctl enable danted

IP=$(curl -s ifconfig.me)

if [[ "$ENABLE_TELEGRAM" == "1" ]]; then
    MSG="socks5://$USERNAME:$PASSWORD@$IP:$PORT"
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$USER_ID" \
        -d text="$MSG"
fi
