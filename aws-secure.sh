#!/bin/bash
set -euo pipefail

# ======== HÀM HỖ TRỢ ========

notify_telegram() {
    local message="$1"
    local bot_token="$2"
    local user_id="$3"
    curl -fsS -X POST "https://api.telegram.org/bot${bot_token}/sendMessage" \
        -d "chat_id=${user_id}" \
        --data-urlencode "text=${message}" >/dev/null 2>&1
    return $?
}

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
    local attempt="$4"
    local bot_token="$5"
    local user_id="$6"
    local username="${7:-proxyuser}"

    echo "[INIT] Cài đặt proxy SOCKS5 cho user: $username (port: $port)" >&2

    apt-get update -y >/dev/null
    apt-get install -y dante-server net-tools curl >/dev/null

    # Cấu hình Dante
    cat > /etc/danted.conf <<EOF
logoutput: syslog
internal: eth0 port = $port
external: eth0

method: username
user.notprivileged: nobody

client pass {
    from: $allow_ip to: 0.0.0.0/0
}

pass {
    from: $allow_ip to: 0.0.0.0/0
    protocol: tcp udp
    method: username
}
EOF

    # Tạo user SOCKS5
    if ! id "$username" &>/dev/null; then
        useradd -M -s /usr/sbin/nologin "$username"
    fi
    echo "${username}:${password}" | chpasswd

    # Tự động mở port SG
    open_security_group_port "$port"

    # Bật service
    systemctl enable danted >/dev/null 2>&1 || true
    systemctl restart danted >/dev/null 2>&1 || true

    # Lấy IP public
    local ip
    ip=$(curl -s https://api.ipify.org || curl -s ifconfig.me || curl -s icanhazip.com || hostname -I | awk '{print $1}' || echo "UNKNOWN")
    ip=$(echo "$ip" | tr -d ' \n\r')

    local PROXY_LINE="${ip}:${port}:${username}:${password}"

    # Gửi Telegram (retry 3 lần)
    local retries=0
    local sent=false
    until [[ $retries -ge 3 ]]; do
        if notify_telegram "$PROXY_LINE" "$bot_token" "$user_id"; then
            echo "[INFO] Gửi Telegram thành công: $PROXY_LINE"
            sent=true
            break
        fi
        ((retries++))
        echo "[WARN] Thử lại sau 10s..."
        sleep 10
    done

    # ====== Lưu thông tin vào file cấu hình ======
    cat > /etc/socks5-proxy.conf <<EOF
IP=${ip}
PORT=${port}
USER=${username}
PASS=${password}
BOT_TOKEN=${bot_token}
USER_ID=${user_id}
EOF

    # ====== Tạo script thông báo lại khi service start ======
    cat > /usr/local/bin/notify-proxy.sh <<'NOTIFY'
#!/bin/bash
if [[ -f /etc/socks5-proxy.conf ]]; then
    source /etc/socks5-proxy.conf
    IP_NOW=$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}' || echo "$IP")
    MSG="${IP_NOW}:${PORT}:${USER}:${PASS}"
    curl -fsS -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${USER_ID}" \
        --data-urlencode "text=${MSG}" >/dev/null 2>&1 || true
fi
NOTIFY

    chmod +x /usr/local/bin/notify-proxy.sh

    # ====== Tạo systemd service để auto gửi lại thông tin khi start ======
    cat > /etc/systemd/system/proxy-notify.service <<EOF
[Unit]
Description=Notify proxy info to Telegram after start
After=network-online.target danted.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/notify-proxy.sh

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable proxy-notify.service >/dev/null 2>&1
    systemctl start proxy-notify.service >/dev/null 2>&1

    echo "[DONE] Proxy SOCKS5 đã được cấu hình và tự động gửi lại khi start!"
}
