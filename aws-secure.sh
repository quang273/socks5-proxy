#!/bin/bash
set -euo pipefail

# ======== HÀM HỖ TRỢ ========

# Gửi thông báo về Telegram (trả về exit code của curl: 0 = thành công)
notify_telegram() {
    local message="$1"
    local bot_token="$2"
    local user_id="$3"
    # Sử dụng --data-urlencode để bảo toàn dấu ":" và ký tự đặc biệt
    curl -fsS -X POST "https://api.telegram.org/bot${bot_token}/sendMessage" \
        -d "chat_id=${user_id}" \
        --data-urlencode "text=${message}" >/dev/null 2>&1
    return $?
}

# Tự động mở port trong Security Group (nếu có quyền AWS CLI)
open_security_group_port() {
    local port="$1"
    if command -v aws >/dev/null 2>&1; then
        local instance_id region sg_id
        instance_id=$(curl -s http://169.254.169.254/latest/meta-data/instance-id || true)
        region=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document 2>/dev/null | grep -oP '"region"\s*:\s*"\K[^"]+' || true)
        if [[ -n "$instance_id" && -n "$region" ]]; then
            sg_id=$(aws ec2 describe-instances --instance-id "$instance_id" --region "$region" \
                --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text 2>/dev/null || true)
            if [[ -n "$sg_id" && "$sg_id" != "None" ]]; then
                echo "[INFO] Mở port ${port}/tcp trong Security Group: ${sg_id}"
                aws ec2 authorize-security-group-ingress \
                    --group-id "$sg_id" \
                    --protocol tcp \
                    --port "$port" \
                    --cidr 0.0.0.0/0 \
                    --region "$region" 2>/dev/null || true
            fi
        fi
    fi
}

# ======== HÀM CHÍNH ========

setup_proxy_single_port() {
    local port="$1"
    local password="$2"
    local allow_ip="$3"
    local attempt="$4"   # not used currently but kept for compatibility
    local bot_token="$5"
    local user_id="$6"
    local username="${7:-mr.quang}"

    echo "[INIT] Cài đặt proxy SOCKS5 cho user: $username (port: $port)" >&2

    # Cài đặt dante-server (SOCKS5)
    apt-get update -y >/dev/null
    apt-get install -y dante-server net-tools >/dev/null

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

    # Tự động bật port trong Security Group (nếu có AWS CLI & permission)
    open_security_group_port "$port"

    # Khởi động Dante và bật khởi động cùng hệ thống
    systemctl enable danted >/dev/null 2>&1 || true
    systemctl restart danted >/dev/null 2>&1 || true

    # Lấy IP public (fallbacks)
    local ip
    ip=$(curl -s https://api.ipify.org || curl -s ifconfig.me || curl -s icanhazip.com || hostname -I | awk '{print $1}' || echo "UNKNOWN")
    ip=$(echo "$ip" | tr -d ' \n\r')  # trim whitespace/newline

    # Chuẩn hoá message: ip:port:user:pass (chỉ đúng định dạng này)
    local PROXY_LINE="${ip}:${port}:${username}:${password}"

    # Retry gửi Telegram tối đa 3 lần, mỗi lần chờ 10 giây
    local retries=0
    local max_retries=3
    local sent=1
    while (( retries < max_retries )); do
        if notify_telegram "$PROXY_LINE" "$bot_token" "$user_id"; then
            echo "[INFO] Gửi Telegram thành công: $PROXY_LINE" >&2
            sent=0
            break
        else
            retries=$((retries + 1))
            echo "[WARN] Gửi Telegram thất bại (lần $retries). Thử lại sau 10s..." >&2
            sleep 10
        fi
    done

    if (( sent != 0 )); then
        echo "[ERROR] Không thể gửi thông báo Telegram sau ${max_retries} lần. Thông tin proxy: $PROXY_LINE" >&2
    fi

    echo "[DONE] Proxy SOCKS5 đã được cấu hình hoàn tất!" >&2
}

# EOF
