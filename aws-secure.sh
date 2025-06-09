#!/bin/bash

set -euo pipefail

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

validate_port() {
    local port=$1
    if ! [[ $port =~ ^[0-9]+$ ]] || (( port < 1024 || port > 65535 )); then
        echo "ERROR: Port must be a number between 1024 and 65535."
        exit 1
    fi
}

validate_ip() {
    local ip=$1
    if ! [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "ERROR: IP address format invalid."
        exit 1
    fi
    # Check each octet <= 255
    IFS='.' read -r -a octets <<< "$ip"
    for o in "${octets[@]}"; do
        if (( o < 0 || o > 255 )); then
            echo "ERROR: IP address octet $o out of range."
            exit 1
        fi
    done
}

validate_not_empty() {
    local val=$1
    local name=$2
    if [[ -z "$val" ]]; then
        echo "ERROR: $name cannot be empty."
        exit 1
    fi
}

# Đọc biến đầu vào (theo thứ tự)
read -r INSTALL_MODE CONFIG_MODE ENABLE_TELEGRAM BOT_TOKEN USER_ID PORT PASSWORD ALLOW_IP

log "Validating input parameters..."

validate_port "$PORT"
validate_ip "$ALLOW_IP"
validate_not_empty "$BOT_TOKEN" "BOT_TOKEN"
validate_not_empty "$USER_ID" "USER_ID"
validate_not_empty "$PASSWORD" "PASSWORD"

log "Parameters valid. Proceeding..."

# Sinh username ngẫu nhiên 6 ký tự a-z0-9
USERNAME="user$(head /dev/urandom | tr -dc a-z0-9 | head -c6)"

log "Generated username: $USERNAME"

log "Updating package list and installing required packages..."
apt update -y
apt install -y dante-server curl iptables

log "Detecting main network interface..."
IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')

log "Interface detected: $IFACE"

log "Writing Dante configuration..."
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

log "Removing old user if exists and creating new user..."
userdel -r "$USERNAME" 2>/dev/null || true
useradd -M -s /bin/false "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd

log "Restarting and enabling Dante service..."
systemctl restart danted
systemctl enable danted

log "Setting iptables rules..."

# Xóa các rule cũ có thể trùng (để tránh tràn rule)
iptables -D INPUT -p tcp --dport "$PORT" ! -s "$ALLOW_IP" -j DROP 2>/dev/null || true
iptables -D OUTPUT -p udp --dport 53 -j DROP 2>/dev/null || true

# Thêm rule mới
iptables -A INPUT -p tcp --dport "$PORT" ! -s "$ALLOW_IP" -j DROP
# Cho phép DNS UDP ra localhost (vd: systemd-resolved)
iptables -A OUTPUT -p udp --dport 53 -d 127.0.0.53 -j ACCEPT
# Chặn DNS UDP khác (để tránh DNS leak)
iptables -A OUTPUT -p udp --dport 53 -j DROP

log "Fetching public IP..."
IP=$(curl -s ifconfig.me)

if [[ "$ENABLE_TELEGRAM" == "1" ]]; then
    PROXY="socks5://$USERNAME:$PASSWORD@$IP:$PORT"
    ENCODED=$(echo -n "$PROXY" | base64)
    log "Sending proxy info to Telegram..."
    curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
        -d chat_id="$USER_ID" \
        -d text="\xf0\x9f\x9a\x80 Proxy mới (base64): \`$ENCODED\`" \
        -d parse_mode="Markdown"
    log "Proxy info sent."
fi

log "Setup completed successfully."
