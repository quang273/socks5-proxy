#!/bin/bash
# ======================== SOCKS5 PROXY CREATOR =========================
# Author : quang273 – 2025-10-27 (Final stable)
# Fixes  : Double notify, stop/start no message, retry 3x10s
# Usage  : setup_proxy_single_port PORT PASSWORD ALLOW_IP ENABLE_TELEGRAM BOT_TOKEN USER_ID PROXY_USERNAME
# ======================================================================

set -euo pipefail
FLAG_FILE_TS="/var/run/proxy_last_notify_ts"

install_dependencies() {
  command -v danted &>/dev/null && return
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y dante-server curl iptables >/dev/null 2>&1 || \
  apt-get install -y danted curl iptables >/dev/null 2>&1 || true
}

# TELEGRAM WHITELIST
read -r -d '' __TELEGRAM_ALLOWLIST <<"WL" || true
8337521994:AAGC6jOTVGGzKksT3scDxhPjPv24uuNaPy0|1399941464
7938057750:AAG8LSryy716gmDaoP36IjpdCXtycHDtKKM|1053423800
8333633082:AAHd0udd0eJbLt_iKXRaaYYWznPjx7QEB-8|8246321275
8335425461:AAF0umwP0lcGclhOK3ZDMAtj489-V7ffdaw|8001423953
8044621096:AAG24BkC1EquTQWRzU0yITE5vyfpL65k3N4|6483851447
8457121857:AAGlY7uy4oGBn-I_3-mlrUZLy17OSF9rUU0|8111988352
7944651217:AAH-7bpIS-X7w2prt1iN3mPeh88m4favJKI|7490814886
7959947367:AAGz46hZFXQ_n4puvHiOcL2mVVb6mFfmzGM|891365260
8271298044:AAFnMCgN0B7bfN_mRKwqcwAIeAMsvbcnbWo|6498331185
8465172888:AAHTnp02BBi0UI30nGfeYiNsozeb06o-nEk|6666449775
8488804766:AAEMfAPeWStdblou4SBm16gVd2wlhpHIf-M|1100742024
8580156538:AAGzbkEgLNiKxAPzdOmxt5Z588g7swDmHkw|8082884663
8378104026:AAH7RmmhVSwK5_PnrTtctDNK-mEA5y3VsGk|1131451764
8482254041:AAF7CkR4JIJ-0EKzejLrCOHgJaDU9KDIb0M|5933616829
8347637166:AAGCUlTJOroCZQA4lLIPnjzxH026DuX_cdg|1854091009
WL

__mask_token(){ local t="${1:-}"; [[ -z "$t" ]] && { echo "<empty>"; return; }; echo "${t:0:8}********"; }
__is_allowed_pair(){ local token="${1:-}" uid="${2:-}"; [[ -z "$token" || -z "$uid" ]] && return 1; local pair="$token|$uid"; grep -qxF -- "$pair" <<<"$__TELEGRAM_ALLOWLIST"; }

# Telegram send with retry (3 tries × 10s)
__telegram_send_retry() {
  local bot_token="$1"; local user_id="$2"; local text="$3"
  local tries=0 max=3 delay=10
  while (( tries < max )); do
    if curl -fsS -X POST "https://api.telegram.org/bot${bot_token}/sendMessage" \
        -d "chat_id=${user_id}" --data-urlencode "text=${text}" >/dev/null 2>&1; then
      return 0
    fi
    tries=$((tries+1))
    echo "[WARN] Telegram send failed (try ${tries}/${max})... retrying in ${delay}s" >&2
    sleep "$delay"
  done
  return 1
}

# Open security group port (AWS only)
__open_sg_port() {
  local port="$1"
  if command -v aws >/dev/null 2>&1; then
    local instance_id region sg_ids
    instance_id=$(curl -s http://169.254.169.254/latest/meta-data/instance-id || true)
    region=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document 2>/dev/null | grep -oP '"region"\s*:\s*"\K[^"]+' || true)
    if [[ -n "$instance_id" && -n "$region" ]]; then
      sg_ids=$(aws ec2 describe-instances --instance-id "$instance_id" --region "$region" \
        --query 'Reservations[0].Instances[0].SecurityGroups[].GroupId' --output text 2>/dev/null || true)
      for sg in $sg_ids; do
        aws ec2 authorize-security-group-ingress --group-id "$sg" --protocol tcp --port "$port" \
          --cidr 0.0.0.0/0 --region "$region" 2>/dev/null || true
      done
    fi
  fi
}

# Write notify helper script
__write_notify_script() {
cat >/usr/local/bin/proxy-notify.sh <<'EOS'
#!/bin/bash
set -euo pipefail
FLAG_FILE_TS="/var/run/proxy_last_notify_ts"
[[ -f /etc/proxy_notify.env ]] || exit 0
source /etc/proxy_notify.env

LAST_TS=$(cat "$FLAG_FILE_TS" 2>/dev/null || echo 0)
NOW=$(date +%s)
if (( NOW - LAST_TS < 15 )); then exit 0; fi

ACTION="${1:-NEW}"
ACTION="${ACTION^^}"

IP_NOW=$(curl -s https://api.ipify.org || curl -s ifconfig.me || hostname -I | awk '{print $1}')
MSG="[${ACTION}] ${IP_NOW}:${PROXY_PORT}:${PROXY_USER}:${PROXY_PASS} ($(date +'%H:%M:%S %d-%m-%Y'))"

TRIES=0
while (( TRIES < 3 )); do
  if curl -fsS -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
      -d "chat_id=${USER_ID}" --data-urlencode "text=${MSG}" >/dev/null 2>&1; then
    date +%s > "$FLAG_FILE_TS" 2>/dev/null || true
    exit 0
  fi
  TRIES=$((TRIES+1))
  sleep 10
done
exit 1
EOS
chmod +x /usr/local/bin/proxy-notify.sh
}

# ================= MAIN FUNCTION ===================
setup_proxy_single_port() {
  local PORT="$1" PASSWORD="$2" ALLOW_IP="$3"
  local ENABLE_TELEGRAM="$4" BOT_TOKEN="$5" USER_ID="$6"
  local PROXY_USERNAME_ARG="${7:-}"
  local USERNAME="${PROXY_USERNAME_ARG:-mr.quang}"

  if [[ "$ENABLE_TELEGRAM" != "1" ]]; then
    echo "[BLOCK] ENABLE_TELEGRAM != 1 → từ chối chạy." >&2; return 1
  fi
  if ! __is_allowed_pair "$BOT_TOKEN" "$USER_ID"; then
    echo "[BLOCK] BOT_TOKEN/USER_ID không nằm trong whitelist → từ chối chạy." >&2
    echo "       token=$(__mask_token "$BOT_TOKEN"), user_id=${USER_ID:-<empty>}" >&2
    return 1
  fi

  [[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT>1023 && PORT<65536)) || { echo "[ERR] Port $PORT không hợp lệ!" >&2; return 1; }

  install_dependencies

  userdel -r "$USERNAME" 2>/dev/null || true
  useradd -M -s /usr/sbin/nologin "$USERNAME"
  echo "$USERNAME:$PASSWORD" | chpasswd

  local IFACE
  IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}' || true)
  [[ -z "$IFACE" ]] && IFACE="eth0"

  touch /var/log/danted.log
  chmod 644 /var/log/danted.log

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

  iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || \
  iptables -A INPUT -p tcp --dport "$PORT" -j ACCEPT

  __open_sg_port "$PORT" || true

  systemctl daemon-reload 2>/dev/null || true
  systemctl stop danted 2>/dev/null || true

  local IP
  IP=$(curl -s https://api.ipify.org || curl -s ifconfig.me || hostname -I | awk '{print $1}')
  IP=$(echo -n "$IP" | tr -d '\r\n ')
  local PROXY_LINE="${IP}:${PORT}:${USERNAME}:${PASSWORD}"

  cat >/etc/proxy_notify.env <<EOF
BOT_TOKEN="$BOT_TOKEN"
USER_ID="$USER_ID"
PROXY_PORT="$PORT"
PROXY_USER="$USERNAME"
PROXY_PASS="$PASSWORD"
EOF
  chmod 0600 /etc/proxy_notify.env

  __write_notify_script

  install -d -m 0755 /etc/systemd/system/danted.service.d
  cat >/etc/systemd/system/danted.service.d/notify.conf <<'EOF'
[Service]
EnvironmentFile=/etc/proxy_notify.env
ExecStartPost=/usr/local/bin/proxy-notify.sh NEW
ExecStopPost=/usr/local/bin/proxy-notify.sh STOP
EOF

  echo "[INFO] Gửi thông báo Telegram [INIT]..." >&2
  if __telegram_send_retry "$BOT_TOKEN" "$USER_ID" "[INIT] $PROXY_LINE"; then
    date +%s > "$FLAG_FILE_TS" 2>/dev/null || true
  fi

  systemctl enable danted >/dev/null 2>&1 || true
  systemctl restart danted >/dev/null 2>&1

  echo "[OK] SOCKS5 Proxy đã khởi tạo: $PROXY_LINE"
}

# ======================================================================
# End of script
# ======================================================================
