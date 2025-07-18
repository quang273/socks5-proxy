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
logoutput: stderr
internal: 0.0.0.0 port=$PROXY_PORT
external: ${EXTERNAL_IP}
socksmethod: username
user.privileged: root
user.notprivileged: nobody
client pass {
                from: 0.0.0.0/0 to: 0.0.0.0/0
                log: error connect disconnect
            }
socks pass {
                from: 0.0.0.0/0 to: 0.0.0.0/0
                log: error connect disconnect
            }
EOF

    # Create proxy user
    echo "Creating proxy user '$PROXY_USER'..."
    if id -u "$PROXY_USER" >/dev/null 2>&1; then
        echo "User '$PROXY_USER' already exists. Skipping user creation."
    else
        sudo useradd -r -s /bin/false "$PROXY_USER"
        echo "$PROXY_USER:$PROXY_PASS" | sudo chpasswd
    fi

    # Restart and enable Dante service
    echo "Restarting and enabling Dante service..."
    if command -v systemctl &> /dev/null; then
        sudo systemctl daemon-reload # Reload systemd configs
        sudo systemctl restart danted
        sudo systemctl enable danted
        sudo systemctl status danted --no-pager || echo "Warning: Dante service status check failed." # Display status, don't exit if it fails
    else
        echo "Warning: systemctl not found. Dante service may not be fully managed. Trying service restart."
        sudo service danted restart || echo "Warning: Failed to restart danted service using 'service'." # Fallback for non-systemd systems
    fi

    # Send proxy details to Telegram (from the VM itself)
    if [ -n "$BOT_TOKEN" ] && [ -n "$USER_ID" ] && [ -n "$EXTERNAL_IP" ]; then
        TELEGRAM_MESSAGE="${EXTERNAL_IP}:${PROXY_PORT}:${PROXY_USER}:${PROXY_PASS}"
        echo "Sending proxy details to Telegram..."
        curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
             -d chat_id="${USER_ID}" \
             -d text="${TELEGRAM_MESSAGE}" > /dev/null # Suppress curl output
        if [ $? -eq 0 ]; then
            echo "Telegram notification sent successfully."
        else
            echo "Error: Failed to send Telegram notification."
        fi
    else
        echo "Skipping Telegram notification from VM: BOT_TOKEN, USER_ID, or EXTERNAL_IP not fully available."
    fi

    echo "SOCKS5 proxy installation complete on this VM."
}

# --- Main deployment logic for Cloud Shell ---

# Robust check for Cloud Shell environment
# This script determines its execution context (Cloud Shell vs. GCE VM)
# If CLOUD_SHELL environment variable is 'true', it's Cloud Shell.
# Otherwise, it checks if it's a GCE VM by querying instance metadata.
# The 'startup-script-url' metadata is only present when passed to a VM.

# Check if we are inside a Google Cloud Shell session
# CLOUD_SHELL is a well-known environment variable set by Cloud Shell.
if [[ "$CLOUD_SHELL" == "true" ]]; then
    echo "Script detected running in Google Cloud Shell. Starting main deployment process (project and instance creation)..."

    # Temporarily disable 'set -e' for the main loop to allow error handling and retries for project creation.
    # This ensures that if a single project creation fails, the script attempts to continue with others.
    set +e 
    
    # Initialize counters for the loop
    SUCCESSFUL_PROJECT_COUNT=0
    ATTEMPT_COUNT=0

    # Loop until the desired number of projects are successfully created
    while [ "$SUCCESSFUL_PROJECT_COUNT" -lt "$NUM_PROJECTS_TO_CREATE" ]; do
      ATTEMPT_COUNT=$((ATTEMPT_COUNT + 1))
      echo -e "\n>>> Attempting to create project [Attempt ${ATTEMPT_COUNT}]..."

      # Each project creation attempt runs in a subshell.
      # 'set -e' is re-enabled inside the subshell to catch errors specific to that project's setup.
      ( 
        set -e # Enable set -e inside this subshell to catch errors for individual project creation

        # Generate a unique project ID using a random number to avoid conflicts
        PROJECT_ID="${PROJECT_PREFIX}-${RANDOM}"
        
        echo -e "\n>>> Trying to create project: $PROJECT_ID"
        
        # 1. Create the project
        echo "Creating project '$PROJECT_ID'..."
        if ! gcloud projects create "$PROJECT_ID" --name="$PROJECT_ID" 2>&1 | tee /dev/fd/2 | grep -q "ERROR"; then
          echo "Project '$PROJECT_ID' created successfully."
        else
          echo "!!! Error: Failed to create project '$PROJECT_ID'. This might be due to a duplicate ID, quota limit, or other issue."
          echo "Attempting to clean up any partially created project '$PROJECT_ID'."
