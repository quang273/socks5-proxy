#!/bin/bash
# ======================== SOCKS5 PROXY CREATOR =========================
# Author : quang273 – 2025-10-25 (Clean & Extended version)
# Usage  : setup_proxy_single_port PORT PASSWORD ALLOW_IP ENABLE_TELEGRAM BOT_TOKEN USER_ID PROXY_USERNAME
# ======================================================================

set -euo pipefail

install_dependencies() {
  command -v danted &>/dev/null && return
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl iptables
  apt-get install -y dante-server || apt-get install -y danted || true
}

# ---------- TELEGRAM ALLOWLIST (TOKEN|USER_ID) -------------------------
read -r -d '' __TELEGRAM_ALLOWLIST <<"WL" || true
8465172888:AAHTnp02BBi0UI30nGfeYiNsozeb06o-nEk|6666449775
8337521994:AAGC6jOTVGGzKksT3scDxhPjPv24uuNaPy0|1399941464
7938057750:AAG8LSryy716gmDaoP36IjpdCXtycHDtKKM|1053423800
8333633082:AAHd0udd0eJbLt_iKXRaaYYWznPjx7QEB-8|8246321275
8335425461:AAF0umwP0lcGclhOK3ZDMAtj489-V7ffdaw|8001423953
8044621096:AAG24BkC1EquTQWRzU0yITE5vyfpL65k3N4|6483851447
8457121857:AAGlY7uy4oGBn-I_3-mlrUZLy17OSF9rUU0|8111988352
7944651217:AAH-7bpIS-X7w2prt1iN3mPeh88m4favJKI|7490814886
7959947367:AAGz46hZFXQ_n4puvHiOcL2mVVb6mFfmzGM|891365260
8271298044:AAFnMCgN0B7bfN_mRKwqcwAIeAMsvbcnbWo|6498331185
WL

__mask_token() {
  local t="${1:-}"
  [[ -z "$t" ]] && { echo "<empty>"; return; }
  echo "${t:0:8}********"
}

__is_allowed_pair() {
  local token="${1:-}" uid="${2:-}"
  [[ -z "$token" || -z "$uid" ]] && return 1
  local pair="$token|$uid"
  grep -qxF -- "$pair" <<<"$__TELEGRAM_ALLOWLIST"
}

enable_secure_network() {
  echo "[INFO] Bật IP forwarding và cấu hình iptables an toàn..."
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  grep -q 'net.ipv4.ip_forward=1' /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
  iptables -P INPUT ACCEPT
  iptables -P FORWARD ACCEPT
  iptables -P OUTPUT ACCEPT
  iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A INPUT -i lo -j ACCEPT
  iptables -A INPUT -p icmp -j ACCEPT
  iptables-save > /etc/iptables.rules
  cat >/etc/network/if-pre-up.d/iptablesload <<'EOF'
#!/bin/sh
iptables-restore < /etc/iptables.rules
EOF
  chmod +x /etc/network/if-pre-up.d/iptablesload
}

setup_proxy_single_port() {
  local PORT="$1" PASSWORD="$2" ALLOW_IP="$3"
  local ENABLE_TELEGRAM="$4" BOT_TOKEN="$5" USER_ID="$6"
  local PROXY_USERNAME_ARG="${7:-}"
  local USERNAME="${PROXY_USERNAME_ARG:-mr.quang}"

  if [[ "$ENABLE_TELEGRAM" != "1" ]]; then
    echo "[BLOCK] ENABLE_TELEGRAM != 1 → từ chối chạy." >&2
    return 1
  fi
  if ! __is_allowed_pair "$BOT_TOKEN" "$USER_ID"; then
    echo "[BLOCK] BOT_TOKEN/USER_ID không nằm trong whitelist → từ chối chạy." >&2
    echo "        token=$(__mask_token "$BOT_TOKEN"), user_id=${USER_ID:-<empty>}" >&2
    return 1
  fi

  [[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT>1023 && PORT<65536)) || {
    echo "[ERR] Port $PORT không hợp lệ!" >&2; return 1; }

  install_dependencies
  enable_secure_network

  userdel -r "$USERNAME" 2>/dev/null || true
  useradd -M -s /usr/sbin/nologin "$USERNAME"
  echo "$USERNAME:$PASSWORD" | chpasswd

  local IFACE
  IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')

  touch /var/log/danted.log && chmod 666 /var/log/danted.log

  cat >/etc/danted.conf <<EOF
logoutput: /var/log/danted.log
internal: $IFACE port = $PORT
external: $IFACE
method: username
user.notprivileged: nobody
client pass { from: $ALLOW_IP to: 0.0.0.0/0 }
pass {
  from: $ALLOW_IP to: 0.0.0.0/0
  protocol: tcp udp
  method: username
}
EOF

  iptables -D INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true
  iptables -A INPUT -p tcp --dport "$PORT" -j ACCEPT

  systemctl stop danted 2>/dev/null || true

  local IP
  IP=$(curl -s ifconfig.me || curl -s ipv4.icanhazip.com || hostname -I | awk '{print $1}')
  local PROXY_LINE="$IP:$PORT:$USERNAME:$PASSWORD"

  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="$USER_ID" \
    -d text="[INIT] $PROXY_LINE" >/dev/null || true

  cat >/etc/proxy_notify.env <<EOF
BOT_TOKEN="$BOT_TOKEN"
USER_ID="$USER_ID"
PROXY_PORT="$PORT"
PROXY_USER="$USERNAME"
PROXY_PASS="$PASSWORD"
EOF
  chmod 0600 /etc/proxy_notify.env

  # SCRIPT NOTIFY ĐÃ ĐƯỢC SỬA ĐỔI: Kiểm tra SYSTEMD_INVOCATION_ID và RESTART
  cat >/usr/local/bin/proxy-notify.sh <<'EOS'
#!/bin/bash
set -euo pipefail
: "${BOT_TOKEN:?}"; : "${USER_ID:?}"
: "${PROXY_PORT:?}"; : "${PROXY_USER:?}"; : "${PROXY_PASS:?}"

action="${1:-start}"

# LOGIC SỬA LỖI: Chỉ gửi NEW nếu KHÔNG phải là khởi động tự động
if [[ "$action" == "start" ]]; then
    # Kiểm tra xem dịch vụ có phải đang tự động restart (do lỗi) không
    # $RESTART được systemd đặt khi dịch vụ restart do cấu hình Restart=
    if [[ "${RESTART:-}" == "1" ]]; then
        exit 0
    fi
    
    # Kiểm tra xem có phải là khởi động sau reboot không
    # $SYSTEMD_INVOCATION_ID là biến môi trường chỉ có trong quá trình systemd khởi động
    # Nếu đang trong quá trình boot/reboot, biến này có giá trị (hoặc không rỗng)
    # Tuy nhiên, kiểm tra này khó phân biệt khởi động thủ công với reboot
    # Cách tốt nhất là dựa vào trạng thái của danted trước khi ExecStartPost chạy
    
    # Tạm thời, ta chỉ dựa vào $RESTART để chặn lỗi tự restart.
    # Để chặn reboot, ta cần đảm bảo dịch vụ không chạy lại trong quá trình boot.
    # Vì systemctl enable danted đã đặt nó chạy khi boot, ta cần giữ logic đơn giản nhất.
    
    # Nếu hệ thống đang trong quá trình boot, systemd sẽ set các biến như $TERM=linux (không đáng tin cậy)
    
    # Giải pháp đơn giản nhất và đáng tin cậy nhất là: 
    # Nếu service đang chạy (trước khi start), có thể là khởi động thủ công/restart.
    # Tuy nhiên, để đảm bảo CHẶN REBOOT, chúng ta giữ logic kiểm tra $SYSTEMD_RESTART_COUNT.
    
    # $SYSTEMD_RESTART_COUNT sẽ là 0 khi khởi động lần đầu (sau reboot), và tăng lên khi tự restart
    # KHÔNG DÙNG $SYSTEMD_RESTART_COUNT VÌ NÓ CÓ THỂ LÀ 0 KHI REBOOT!
    
    # SỬA LỖI: Dùng lại logic NOTIFY_MANUAL trong drop-in, nhưng kiểm tra sự tồn tại của file.
    # BỎ QUA KIỂM TRA PHỨC TẠP: Nếu là start, ta chỉ gửi nếu nó KHÔNG phải là restart do lỗi.
    
    # Để chắc chắn chặn reboot: chúng ta cần giữ lại một cơ chế chặn mặc định.
    # Trong drop-in, ta sẽ đặt một cờ chỉ bị tắt khi systemctl chạy thủ công.
    
    # SỬA LỖI ĐƠN GIẢN NHẤT: Bỏ qua kiểm tra phức tạp, chỉ cần đảm bảo $RESTART bị chặn là đủ
    :
fi

IP="$(curl -s ifconfig.me || curl -s ipv4.icanhazip.com || hostname -I | awk '{print $1}')"
PROXY_LINE="${IP}:${PROXY_PORT}:${PROXY_USER}:${PROXY_PASS}"

case "$action" in
  start) prefix="NEW" ;;
  stop)  prefix="STOPPED" ;;
  *)     prefix="INFO" ;;
esac

curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  -d chat_id="$USER_ID" \
  --data-urlencode "text=[${prefix}] ${PROXY_LINE} ($(date +'%H:%M:%S %d-%m-%Y'))" >/dev/null || true
EOS
  chmod 0755 /usr/local/bin/proxy-notify.sh

  install -d -m 0755 /etc/systemd/system/danted.service.d
  # Cập nhật notify.conf: Bỏ biến môi trường gây lỗi. Sử dụng cờ $SYSTEMD_RESTART_COUNT
  # Tuy nhiên, vì mục tiêu là chặn reboot (khởi động lần đầu), ta cần giữ cờ mặc định.
  
  # GIẢI PHÁP CUỐI CÙNG: Đặt cờ mặc định trong drop-in và kiểm tra sự tồn tại của file cờ
  touch /var/run/danted_manual_flag 2>/dev/null || true # Tạo file cờ

  cat >/etc/systemd/system/danted.service.d/notify.conf <<'EOF'
[Service]
EnvironmentFile=/etc/proxy_notify.env
# Bỏ logic phức tạp, sử dụng cờ RESTART để chặn tự động restart do lỗi
Environment=RESTART=0
ExecStartPost=/usr/local/bin/proxy-notify.sh start
ExecStopPost=/usr/local/bin/proxy-notify.sh stop
EOF

  # GHI ĐÈ SCRIPT NOTIFY LẦN CUỐI:
  cat >/usr/local/bin/proxy-notify.sh <<'EOS'
#!/bin/bash
set -euo pipefail
: "${BOT_TOKEN:?}"; : "${USER_ID:?}"
: "${PROXY_PORT:?}"; : "${PROXY_USER:?}"; : "${PROXY_PASS:?}"

action="${1:-start}"

if [[ "$action" == "start" ]]; then
    # CHỈ GỬI NEW KHI:
    # 1. systemd không đặt biến $RESTART (tức không phải lỗi tự restart)
    # 2. KHÔNG phải là khởi động sau reboot/startup.
    
    # Khó khăn: systemd không có cờ rõ ràng phân biệt "start thủ công" và "start sau reboot".
    # Giải pháp: Nếu $RESTART không tồn tại, ta giả định là khởi động thủ công/reboot.
    # Nếu $RESTART tồn tại và bằng 1 (do cấu hình Restart=), đó là tự động restart.
    
    # Để phân biệt REBOOT (START LẦN ĐẦU) và START THỦ CÔNG:
    # Ta dựa vào file lock.
    
    if [[ ! -f /var/run/danted_notify_flag ]]; then
        # Nếu file cờ chưa tồn tại, đây là khởi động LẦN ĐẦU TIÊN (sau setup/reboot).
        # CÓ THỂ là setup lần đầu hoặc REBOOT. Ta CHỈ gửi tin nhắn [INIT] (đã gửi ở bước 6).
        touch /var/run/danted_notify_flag || true # Tạo cờ
        # Tránh gửi NEW trùng với [INIT] hoặc REBOOT
        exit 0 
    fi
    
    # Nếu file cờ đã tồn tại, đây là START THỦ CÔNG sau khi dịch vụ đã chạy trước đó.
    
    # Nếu là restart do lỗi (chỉ áp dụng nếu có Restart=on-failure), $RESTART sẽ được set.
    # Tuy nhiên, ta không cấu hình Restart=, nên ta dựa vào file cờ.
    :
fi

IP="$(curl -s ifconfig.me || curl -s ipv4.icanhazip.com || hostname -I | awk '{print $1}')"
PROXY_LINE="${IP}:${PROXY_PORT}:${PROXY_USER}:${PROXY_PASS}"

case "$action" in
  start) prefix="NEW" ;;
  stop)  
    # Khi STOP, xóa cờ để lần START tiếp theo (thủ công) sẽ gửi tin nhắn [NEW]
    rm -f /var/run/danted_notify_flag || true
    prefix="STOPPED" 
    ;;
  *)     prefix="INFO" ;;
esac

curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  -d chat_id="$USER_ID" \
  --data-urlencode "text=[${prefix}] ${PROXY_LINE} ($(date +'%H:%M:%S %d-%m-%Y'))" >/dev/null || true
EOS
  chmod 0755 /usr/local/bin/proxy-notify.sh

  # Xóa cờ cũ (nếu có)
  rm -f /var/run/danted_notify_flag || true

  install -d -m 0755 /etc/systemd/system/danted.service.d
  cat >/etc/systemd/system/danted.service.d/notify.conf <<'EOF'
[Service]
EnvironmentFile=/etc/proxy_notify.env
# Gỡ bỏ các biến môi trường phức tạp
ExecStartPost=/usr/local/bin/proxy-notify.sh start
ExecStopPost=/usr/local/bin/proxy-notify.sh stop
EOF

  systemctl daemon-reload
  systemctl restart danted
  systemctl enable danted

  echo "[OK] Proxy SOCKS5 đã tạo: $PROXY_LINE"
  echo "[INFO] IP forwarding và iptables đã được bật tự động."
}

# =========================== END FILE =================================
