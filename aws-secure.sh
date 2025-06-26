#!/bin/bash
# =====================================================
#  aws-secure.sh – quang273 / 2025-06-25
#  Hàm: setup_proxy_single_port PORT PASSWORD ALLOW_IP \
#                               ENABLE_TELEGRAM BOT_TOKEN USER_ID \
#                               IQSCORE_API_KEY
#
#  Sửa đổi bởi AI (Gemini) - 2025-06-26
#  Thêm tính năng kiểm tra danh tiếng IP
# =====================================================

# Màu sắc cho thông báo
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Hàm hiển thị thông báo lỗi và thoát
error_exit() {
    echo -e "${RED}[LỖI]${NC} $1" >&2
    exit 1
}

# Hàm hiển thị thông báo thành công
success_msg() {
    echo -e "${GREEN}[THÀNH CÔNG]${NC} $1"
}

# Hàm hiển thị thông báo cảnh báo
warn_msg() {
    echo -e "${YELLOW}[CẢNH BÁO]${NC} $1"
}

# --- 1. Cài đặt các gói cần thiết (một lần) ---
install_dependencies() {
    command -v danted &>/dev/null
    if [ $? -eq 0 ]; then
        success_msg "Dante Server đã được cài đặt."
        return 0
    fi

    echo -e "${YELLOW}[INFO]${NC} Đang cài đặt các gói cần thiết: dante-server, curl, iptables..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || error_exit "Không thể cập nhật danh sách gói."
    apt-get install -y dante-server curl iptables || error_exit "Không thể cài đặt các gói cần thiết."
    success_msg "Các gói cần thiết đã được cài đặt thành công."
}

# --- 2. Hàm lấy địa chỉ IP công cộng của server ---
get_public_ip() {
    local IP
    # Thử các dịch vụ khác nhau để lấy IP công cộng, đảm bảo độ tin cậy
    IP=$(curl -s --max-time 5 ifconfig.me)
    [[ -z "$IP" ]] && IP=$(curl -s --max-time 5 ipecho.net/plain)
    [[ -z "$IP" ]] && IP=$(curl -s --max-time 5 checkip.amazonaws.com)
    [[ -z "$IP" ]] && IP=$(hostname -I | awk '{print $1; exit}') # Fallback cho IP nội bộ nếu không có IP công cộng

    if [[ -z "$IP" ]]; then
        warn_msg "Không thể lấy được địa chỉ IP công cộng."
        echo "0.0.0.0" # Trả về 0.0.0.0 nếu không tìm thấy IP
    else
        echo "$IP"
    fi
}

# --- 3. Hàm kiểm tra danh tiếng IP bằng dịch vụ bên thứ ba (IPQualityScore) ---
# LƯU Ý QUAN TRỌNG:
# 1. Bạn cần ĐĂNG KÝ TÀI KHOẢN và lấy API_KEY từ dịch vụ IPQualityScore (https://www.ipqualityscore.com).
# 2. Các dịch vụ này thường có giới hạn số lượng request miễn phí hoặc yêu cầu trả phí.
# 3. Kết quả từ các dịch vụ này chỉ là MỘT CHỈ SỐ. KHÔNG CÓ CÔNG CỤ NÀO CÓ THỂ CHẮC CHẮN
#    cho bạn biết liệu TikTok có "gắn cờ" IP đó hay không, vì thuật toán của TikTok là bí mật.
check_ip_reputation() {
    local IP_TO_CHECK="$1"
    local IQSCORE_API_KEY="$2" # API Key được truyền vào từ hàm gọi

    if [[ -z "$IQSCORE_API_KEY" || "$IQSCORE_API_KEY" == "YOUR_IPQUALITYSCORE_API_KEY" ]]; then
        warn_msg "API Key cho IPQualityScore chưa được cấu hình. Bỏ qua kiểm tra danh tiếng IP."
        return 0 # Không coi là lỗi, chỉ là không kiểm tra
    fi

    echo -e "${YELLOW}[INFO]${NC} Đang kiểm tra danh tiếng IP $IP_TO_CHECK với IPQualityScore..."
    local API_URL="https://www.ipqualityscore.com/api/json/ip/$IQSCORE_API_KEY/$IP_TO_CHECK"
    local RESPONSE=$(curl -s --max-time 10 "$API_URL")

    if [[ -z "$RESPONSE" ]]; then
        warn_msg "Không nhận được phản hồi từ IPQualityScore hoặc lỗi kết nối."
        return 0 # Không coi là lỗi, chỉ là không kiểm tra được
    fi

    # Sử dụng grep -o kết hợp sed để đảm bảo an toàn khi parse JSON đơn giản
    # Chỉ trích xuất các trường mong muốn, đảm bảo không có ký tự đặc biệt gây lỗi
    local FRAUD_SCORE=$(echo "$RESPONSE" | grep -oP '"fraud_score":\K\d+' || echo "N/A")
    local IS_PROXY=$(echo "$RESPONSE" | grep -oP '"proxy":\K(true|false)' || echo "N/A")
    local IS_VPN=$(echo "$RESPONSE" | grep -oP '"vpn":\K(true|false)' || echo "N/A")
    local IS_TOR=$(echo "$RESPONSE" | grep -oP '"tor":\K(true|false)' || echo "N/A")
    local IS_BOT=$(echo "$RESPONSE" | grep -oP '"bot_status":\K(true|false)' || echo "N/A")
    local BLACKLIST_SCORE=$(echo "$RESPONSE" | grep -oP '"blacklist_score":\K\d+' || echo "N/A")

    echo -e "${YELLOW}  - Fraud Score: $FRAUD_SCORE (0-100, càng cao càng rủi ro)"
    echo -e "  - Là Proxy: $IS_PROXY"
    echo -e "  - Là VPN: $IS_VPN"
    echo -e "  - Là Tor: $IS_TOR"
    echo -e "  - Là Bot: $IS_BOT"
    echo -e "  - Blacklist Score: $BLACKLIST_SCORE (0-100, càng cao càng có trong danh sách đen)"

    # Các ngưỡng này có thể điều chỉnh tùy theo mức độ chấp nhận rủi ro của bạn
    if [[ "$FRAUD_SCORE" != "N/A" && "$FRAUD_SCORE" -gt 70 ]] || \
       [[ "$IS_PROXY" == "true" ]] || \
       [[ "$IS_VPN" == "true" ]] || \
       [[ "$IS_TOR" == "true" ]] || \
       [[ "$BLACKLIST_SCORE" != "N/A" && "$BLACKLIST_SCORE" -gt 50 ]]; then
        echo -e "${RED}[CẢNH BÁO CAO]${NC} IP $IP_TO_CHECK có điểm rủi ro CAO hoặc được xác định là proxy/VPN/Tor."
        echo -e "${RED}  IP này CÓ THỂ bị các nền tảng như TikTok gắn cờ."
        return 1 # Trả về 1 nếu IP có rủi ro cao
    else
        success_msg "IP $IP_TO_CHECK có điểm rủi ro thấp. Có vẻ ổn."
        return 0 # Trả về 0 nếu IP có vẻ ổn
    fi
}

# --- 4. Hàm khởi tạo proxy ---
setup_proxy_single_port() {
    local PORT="$1" PASSWORD="$2" ALLOW_IP="$3"
    local ENABLE_TELEGRAM="$4" BOT_TOKEN="$5" USER_ID="$6"
    local IQSCORE_API_KEY="$7" # Tham số mới: API Key cho IQScore
    local USERNAME="proxyuser_$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)" # Tên người dùng ngẫu nhiên

    echo -e "${YELLOW}[INFO]${NC} Bắt đầu thiết lập proxy trên cổng $PORT..."

    # 4.1 Kiểm tra port hợp lệ
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1024 || PORT > 65535 )); then
        error_exit "Cổng $PORT không hợp lệ! Vui lòng chọn cổng từ 1024 đến 65535."
    fi

    # 4.2 Kiểm tra mật khẩu
    if [[ -z "$PASSWORD" ]]; then
        error_exit "Mật khẩu không được để trống."
    fi

    # 4.3 Kiểm tra IP cho phép
    if [[ -z "$ALLOW_IP" ]]; then
        warn_msg "IP cho phép (ALLOW_IP) đang trống. Mặc định cho phép tất cả các IP (0.0.0.0/0). CÂN NHẮC VỀ BẢO MẬT!"
        ALLOW_IP="0.0.0.0/0"
    fi

    # 4.4 Cài đặt gói
    install_dependencies

    # Lấy IP công cộng và kiểm tra danh tiếng trước khi cấu hình proxy
    local PUBLIC_IP=$(get_public_ip)
    if [[ "$PUBLIC_IP" == "0.0.0.0" ]]; then
        warn_msg "Không thể lấy IP công cộng để kiểm tra danh tiếng. Tiếp tục cấu hình proxy nhưng IP có thể khó dùng với TikTok."
    else
        # Gọi hàm kiểm tra danh tiếng IP với API Key
        check_ip_reputation "$PUBLIC_IP" "$IQSCORE_API_KEY"
        # Uncomment dòng dưới nếu bạn muốn script dừng lại nếu IP có rủi ro cao:
        # if ! check_ip_reputation "$PUBLIC_IP" "$IQSCORE_API_KEY"; then
        #     error_exit "IP này có rủi ro cao, không tiếp tục cài đặt proxy."
        # fi
    fi

    # 4.5 Lấy interface mặc định
    local IFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
    if [[ -z "$IFACE" ]]; then
        error_exit "Không thể xác định giao diện mạng mặc định."
    fi

    # 4.6 Tạo cấu hình Dante
    echo -e "${YELLOW}[INFO]${NC} Tạo file cấu hình Dante: /etc/danted.conf..."
    cat >/etc/danted.conf <<EOF
logoutput: stderr
internal: $IFACE port = $PORT
external: $IFACE

method: username none
user.notprivileged: nobody

client pass {
  from: $ALLOW_IP to: 0.0.0.0/0
  log: error connect disconnect
}

pass {
  from: $ALLOW_IP to: 0.0.0.0/0
  protocol: tcp udp
  method: username
  log: error connect disconnect
}
EOF
    if [ $? -ne 0 ]; then
        error_exit "Không thể tạo file cấu hình Dante."
    fi
    success_msg "File cấu hình Dante đã được tạo."

    # 4.7 Tạo tài khoản proxy
    echo -e "${YELLOW}[INFO]${NC} Tạo tài khoản người dùng proxy: $USERNAME..."
    id -u "$USERNAME" &>/dev/null
    if [ $? -eq 0 ]; then
        userdel -r "$USERNAME" &>/dev/null
        warn_msg "Đã xóa tài khoản $USERNAME cũ (nếu tồn tại)."
    fi

    useradd -M -s /bin/false "$USERNAME" || error_exit "Không thể tạo người dùng proxy."
    echo "$USERNAME:$PASSWORD" | chpasswd || error_exit "Không thể đặt mật khẩu cho người dùng proxy."
    success_msg "Tài khoản proxy $USERNAME đã được tạo."

    # 4.8 Khởi động dịch vụ
    echo -e "${YELLOW}[INFO]${NC} Khởi động và bật dịch vụ danted..."
    systemctl daemon-reload
    systemctl restart danted || error_exit "Không thể khởi động lại dịch vụ danted. Kiểm tra lỗi trong /var/log/syslog hoặc /var/log/daemon.log."
    systemctl enable danted || error_exit "Không thể bật dịch vụ danted khi khởi động."
    success_msg "Dịch vụ danted đã được khởi động và bật."

    # 4.9 Mở cổng trên firewall
    echo -e "${YELLOW}[INFO]${NC} Mở cổng $PORT trên firewall (iptables)..."
    iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT &>/dev/null
    if [ $? -ne 0 ]; then
        iptables -A INPUT -p tcp --dport "$PORT" -j ACCEPT || error_exit "Không thể mở cổng $PORT trên iptables."
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save || warn_msg "Không thể lưu các quy tắc iptables bằng netfilter-persistent."
        elif command -v iptables-save &>/dev/null; then
            mkdir -p /etc/iptables/ # Đảm bảo thư mục tồn tại
            iptables-save > /etc/iptables/rules.v4
            warn_msg "Đã lưu quy tắc iptables. Đảm bảo hệ thống của bạn tự động tải lại chúng khi khởi động."
        else
            warn_msg "Không tìm thấy công cụ để lưu quy tắc iptables. Quy tắc có thể bị mất sau khi khởi động lại."
        fi
        success_msg "Cổng $PORT đã được mở trên firewall."
    else
        success_msg "Cổng $PORT đã được mở trên firewall trước đó."
    fi

    # 4.10 Gửi thông báo Telegram (nếu bật)
    if [[ "$ENABLE_TELEGRAM" == "1" && -n "$BOT_TOKEN" && -n "$USER_ID" ]]; then
        echo -e "${YELLOW}[INFO]${NC} Đang gửi thông tin proxy đến Telegram..."
        # PUBLIC_IP đã được lấy và kiểm tra ở trên
        if [[ "$PUBLIC_IP" == "0.0.0.0" ]]; then
            warn_msg "Không thể lấy IP công cộng để gửi Telegram. Vui lòng kiểm tra thủ công."
        fi
        local PROXY_LINE="$PUBLIC_IP:$PORT:$USERNAME:$PASSWORD"
        local MESSAGE="*Proxy Dante Mới Được Thiết Lập*\n\nHost: \`$PUBLIC_IP\`\nCổng: \`$PORT\`\nNgười dùng: \`$USERNAME\`\nMật khẩu: \`$PASSWORD\`\n\n_Dành cho truy cập từ: $ALLOW_IP_"

        # Gọi lại hàm kiểm tra danh tiếng IP để có thông tin chi tiết trong tin nhắn Telegram (tùy chọn)
        local IP_CHECK_STATUS="Không có thông tin kiểm tra IP hoặc không cấu hình API Key."
        if [[ -n "$IQSCORE_API_KEY" && "$IQSCORE_API_KEY" != "YOUR_IPQUALITYSCORE_API_KEY" ]]; then
            local IP_REP_RESPONSE=$(curl -s --max-time 5 "https://www.ipqualityscore.com/api/json/ip/$IQSCORE_API_KEY/$PUBLIC_IP")
            local IP_FRAUD_SCORE=$(echo "$IP_REP_RESPONSE" | grep -oP '"fraud_score":\K\d+' || echo "N/A")
            local IP_IS_PROXY=$(echo "$IP_REP_RESPONSE" | grep -oP '"proxy":\K(true|false)' || echo "N/A")

            if [[ "$IP_FRAUD_SCORE" != "N/A" ]]; then
                IP_CHECK_STATUS="Fraud Score: \`$IP_FRAUD_SCORE\` (Proxy: \`$IP_IS_PROXY\`)"
                if [[ "$IP_FRAUD_SCORE" -gt 70 || "$IP_IS_PROXY" == "true" ]]; then
                    IP_CHECK_STATUS+="\n${RED}CẢNH BÁO: IP có rủi ro cao/là proxy!${NC}"
                fi
            fi
        fi
        MESSAGE+="\n\n*Trạng thái IP (Kiểm tra IPQualityScore):*\n$IP_CHECK_STATUS"


        curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
             -d chat_id="$USER_ID" \
             -d parse_mode="Markdown" \
             -d text="$MESSAGE" > /dev/null
        
        if [ $? -eq 0 ]; then
            success_msg "Thông tin proxy đã được gửi đến Telegram."
        else
            warn_msg "Không thể gửi thông tin proxy đến Telegram. Vui lòng kiểm tra BOT_TOKEN và USER_ID."
        fi
    fi

    echo "" # Dòng trống cho dễ nhìn
    success_msg "Thiết lập Proxy Dante HOÀN TẤT!"
    echo -e "${GREEN}Thông tin Proxy:${NC}"
    echo -e "  Địa chỉ IP: $PUBLIC_IP"
    echo -e "  Cổng: $PORT"
    echo -e "  Tên người dùng: $USERNAME"
    echo -e "  Mật khẩu: $PASSWORD"
    echo -e "  Chỉ cho phép từ IP: $ALLOW_IP"
    echo -e "${YELLOW}Lưu ý: Nếu bạn gặp lỗi không kết nối được, hãy kiểm tra lại Firewall và Security Group của server AWS.${NC}"
}

# --- Ví dụ cách sử dụng (có thể bỏ hoặc sửa đổi) ---
# Để kiểm thử hàm setup_proxy_single_port thủ công:
# setup_proxy_single_port <PORT> <PASSWORD> <ALLOW_IP> <ENABLE_TELEGRAM> <BOT_TOKEN> <USER_ID> <IQSCORE_API_KEY>
# Ví dụ:
# setup_proxy_single_port 1080 "M@tkhauCucManh123" "0.0.0.0/0" 1 "YOUR_BOT_TOKEN" "YOUR_USER_ID" "YOUR_IQSCORE_API_KEY"

# ====================== Hết file ======================
