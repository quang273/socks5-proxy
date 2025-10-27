#!/bin/bash
set -euo pipefail

# ======== HÀM HỖ TRỢ ========

# Gửi thông báo về Telegram
notify_telegram() {
    local message="$1"
    local bot_token="$2"
    local user_id="$3"
    curl -s -X POST "https://api.telegram.org/bot${bot_token}/sendMessage" \
        -d "chat_id=${user_id}" \
        -d "text=${message}" >/dev/null 2>&1 || true
}

# Tự động mở port trong Security Group (nếu có quyền AWS CLI)
open_security_group_port() {
    local port="$1"
    if command -v aws >/dev/null 2>&1; then
        local instance_id
        instance_id=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
        local region
        region=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | grep region | awk -F\" '{print $4}')
        local sg_id
        sg_id=$(aws ec2 describe-instances --instance-id "$instance_id" --region "$region" \
            --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text)

        if [[ -n "$sg_id" ]]; then
            echo "[INFO] Mở port ${port}/tcp trong Security Group: ${sg_id}"
            aws ec2 authorize-security-group-ingress \
                --group-id "$sg_id" \
                --protocol tcp \
                --port "$port" \
                --cidr 0.0.0.0/0 \
                --region "$region" 2>/dev/null || true
        fi
    fi
}

# ======== HÀM CHÍNH ========

setup_proxy_single_port() {
    local port="$1"
    local password="$2"
    local allow_ip="$3"
    local attempt="$4"
    local bot_token="$5"
    local user_id="$6"
    local username="$7"

    echo "[INIT] Cài đặt proxy SOCKS5 cho user: $username (port: $port)"

    # Cài đặt dante-server (SOCKS5)
    apt-get update -y && apt-get install -y dante-server net-tools >/dev/null

    # Cấu hình Dante
    cat > /etc/danted.conf <<EOF
logoutput: syslog
internal: eth0 port = $port
external: eth0

method: username
user.notprivileged: nobody

client pass {
    from: $allow_ip to: 0.0.0.0/0
    log: connect disconnect error
}

pass {
    from: $allow_ip to: 0.0.0.0/0
    protocol: tcp udp
    method: username
    log: connect disconnect error
}
EOF

    # Tạo user SOCKS5
    if ! id "$username" &>/dev/null; then
        useradd -M -s /usr/sbin/nologin "$username"
    fi
    echo "${username}:${password}" | chpasswd

    # Tự động bật port trong Security Group
    open_security_group_port "$port"

    # Khởi động Dante và bật khởi động cùng hệ thống
    systemctl enable danted
    systemctl restart danted

    # Lấy IP public
    local ip
    ip=$(curl -s ifconfig.me || curl -s icanhazip.com || echo "UNKNOWN")

    # Gửi thông báo về Telegram với retry 3 lần
    local msg="✅ SOCKS5 READY\nHost: ${ip}\nPort: ${port}\nUser: ${username}\nPass: ${password}"
    local retries=0
    local success=false

    while [[ $retries -lt 3 ]]; do
        if notify_telegram "$msg" "$bot_token" "$user_id"; then
            echo "[INFO] Gửi thông báo Telegram thành công."
            success=true
            break
        else
            echo "[WARN] Gửi thông báo thất bại. Thử lại sau 10 giây..."
            retries=$((retries + 1))
            sleep 10
        fi
    done

    if [[ "$success" == false ]]; then
        echo "[ERROR] Không thể gửi thông báo sau 3 lần thử."
    fi

    echo "[DONE] Proxy SOCKS5 đã được cấu hình hoàn tất!"
}

