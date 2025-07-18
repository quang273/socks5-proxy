#!/bin/bash

# Exit immediately if a command fails.
set -e

# === CONFIGURATION ===
PROJECT_PREFIX="proxyproj"
NUM_PROJECTS_TO_CREATE=3 # Target number of successful projects to create
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
install_socks5_proxy() {
    echo "Starting SOCKS5 proxy installation on this VM..."

    # Update package list and install necessary tools
    sudo apt update -y
    sudo apt install -y curl dante-server

    # Get the external IP of the instance (should be available via metadata)
    # This part is fine when running on a real VM
    EXTERNAL_IP=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)

    echo "Retrieved VM details:"
    echo "  Proxy User: $PROXY_USER"
    echo "  Proxy Port: $PROXY_PORT"
    echo "  External IP: $EXTERNAL_IP"

    # Configure Dante SOCKS5 Server
    echo "Configuring Dante SOCKS5 server..."
    sudo cp /etc/danted.conf /etc/danted.conf.bak || true # Backup, allow failure if not exists
    sudo tee /etc/danted.conf > /dev/null <<EOF
