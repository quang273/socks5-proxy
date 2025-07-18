#!/bin/bash

# Exit immediately if a command fails.
set -e

# === CONFIGURATION ===
# *** ĐẶT PROJECT ID MÀ BẠN MUỐN SỬ DỤNG VÀO ĐÂY ***
# VÍ DỤ: CURENT_GCP_PROJECT_ID="ten-project-cua-ban"
CURRENT_GCP_PROJECT_ID=$(gcloud config get-value project) # Lấy project hiện tại của Cloud Shell

NUM_INSTANCES_PER_PROJECT=8 # Total instances per project (4 Tokyo, 4 Osaka)
ZONE_TOKYO="asia-northeast1-a"
ZONE_OSAKA="asia-northeast2-a"
# SCRIPT_URL này sẽ trỏ lại chính script này trên GitHub
SCRIPT_URL="https://raw.githubusercontent.com/quang273/socks5-proxy/main/install_socks5.sh" 

# Proxy credentials
PROXY_USER="khoitran"
PROXY_PASS="khoi1"
PROXY_PORT="8888"

# Telegram Bot details
BOT_TOKEN="7938057750:AAG8LSryy716gmDaoP36IjpdCXtycHDTKKM"
USER_ID="1053423800"

# --- Function to install SOCKS5 proxy ---
# This function is designed to run on a Compute Engine VM as a startup script.
install_socks5_proxy() {
    echo "Starting SOCKS5 proxy installation on this VM..."

    # Update package list and install necessary tools
    sudo apt update -y
    sudo apt install -y curl dante-server

    # Get the external IP of the instance from metadata service
    EXTERNAL_IP=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)
    if [ -z "$EXTERNAL_IP" ]; then
        echo "Error: Could not retrieve external IP from VM metadata. Exiting proxy installation."
        exit 1
    fi

    echo "Retrieved VM details:"
    echo "  Proxy User: $PROXY_USER"
    echo "  Proxy Port: $PROXY_PORT"
    echo "  External IP: $EXTERNAL_IP"

    # Configure Dante SOCKS5 Server
    echo "Configuring Dante SOCKS5 server..."
    # Backup existing config if it exists
    sudo cp /etc/danted.conf /etc/danted.conf.bak 2>/dev/null || true
    sudo tee /etc/danted.conf > /dev/null <<EOF
