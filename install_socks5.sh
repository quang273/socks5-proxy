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
    EXTERNAL_IP=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)

    echo "Retrieved VM details:"
    echo "  Proxy User: $PROXY_USER"
    echo "  Proxy Port: $PROXY_PORT"
    echo "  External IP: $EXTERNAL_IP"

    # Configure Dante SOCKS5 Server
    echo "Configuring Dante SOCKS5 server..."
    sudo cp /etc/danted.conf /etc/danted.conf.bak || true # Backup, allow failure if not exists
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
    echo "Creating proxy user..."
    sudo useradd -r -s /bin/false "$PROXY_USER"
    echo "$PROXY_USER:$PROXY_PASS" | sudo chpasswd

    # Restart and enable Dante service
    echo "Restarting Dante service..."
    sudo systemctl restart danted
    sudo systemctl enable danted
    sudo systemctl status danted --no-pager || true # Display status, don't exit if it fails

    # Send proxy details to Telegram (from the VM itself)
    if [ -n "$BOT_TOKEN" ] && [ -n "$USER_ID" ] && [ -n "$EXTERNAL_IP" ]; then
        TELEGRAM_MESSAGE="${EXTERNAL_IP}:${PROXY_PORT}:${PROXY_USER}:${PROXY_PASS}"
        curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
             -d chat_id="${USER_ID}" \
             -d text="${TELEGRAM_MESSAGE}"
    else
        echo "Skipping Telegram notification from VM: BOT_TOKEN, USER_ID, or EXTERNAL_IP not fully available."
    fi

    echo "SOCKS5 proxy installation complete on this VM."
}

# --- Main deployment logic ---

# Check if running on a Google Cloud Compute Engine instance
# If the metadata server is reachable, assume it's an instance.
if curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/name &> /dev/null; then
    echo "Script detected running on a Google Cloud Compute Engine instance (as startup script)."
    install_socks5_proxy
    exit 0 # Exit after installing proxy if on VM
else
    echo "Script detected running outside a Google Cloud Compute Engine instance (likely Cloud Shell)."
    if [ -z "$BOT_TOKEN" ] || [ -z "$USER_ID" ]; then
        echo "Warning: BOT_TOKEN or USER_ID not set. Telegram bot functionality may not work for main deployment."
    fi

    echo "Starting main deployment process (project and instance creation)..."

    # Loop until the desired number of projects are successfully created
    while [ "$SUCCESSFUL_PROJECT_COUNT" -lt "$NUM_PROJECTS_TO_CREATE" ]; do
      ATTEMPT_COUNT=$((ATTEMPT_COUNT + 1))
      echo -e "\n>>> Attempting to create project [Attempt ${ATTEMPT_COUNT}]..."

      ( # Start a subshell for each project creation attempt to allow parallel execution
        # Generate a unique project ID
        RAW_ID="${PROJECT_PREFIX}-${RANDOM}"
        PROJECT_ID="$RAW_ID"
        
        echo -e "\n>>> Trying to create project: $PROJECT_ID"
        
        # 1. Create the project
        if ! gcloud projects create "$PROJECT_ID" --name="$PROJECT_ID"; then
          echo "!!! Error: Failed to create project $PROJECT_ID. Might be a duplicate ID, quota limit, or other issue. Skipping this attempt and retrying."
          exit 100 # Exit subshell with a non-zero code to signal failure
        fi

        # 2. Link the billing account
        BILLING_ACCOUNT=$(gcloud beta billing accounts list --format="value(ACCOUNT_ID)" | head -n 1)
        if [ -z "$BILLING_ACCOUNT" ]; then
          echo "!!! Error: No billing account found. Deleting project $PROJECT_ID and retrying."
          gcloud projects delete "$PROJECT_ID" --quiet # Clean up project if billing linking fails
          exit 100
        fi
        echo "Linking project $PROJECT_ID to billing account: $BILLING_ACCOUNT"
        if ! gcloud beta billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"; then
          echo "!!! Error: Failed to link project $PROJECT_ID to billing account. Deleting project $PROJECT_ID and retrying."
          gcloud projects delete "$PROJECT_ID" --quiet
          exit 100
        fi

        # 3. Enable Compute Engine API and set current project
        echo "Enabling Compute Engine API and setting default project for $PROJECT_ID"
        if ! gcloud services enable compute.googleapis.com --project="$PROJECT_ID"; then
          echo "!!! Error: Failed to enable Compute Engine API for project $PROJECT_ID. Deleting project $PROJECT_ID and retrying."
          gcloud projects delete "$PROJECT_ID" --quiet
          exit 100
        fi
        gcloud config set project "$PROJECT_ID"

        # 4. Add firewall rule to allow proxy ports
        echo "Adding 'allow-proxy' firewall rule for project $PROJECT_ID"
        if ! gcloud compute firewall-rules create allow-proxy --project="$PROJECT_ID" \
          --allow=tcp:$PROXY_PORT,tcp:1080,tcp:443 \
          --direction=INGRESS \
          --priority=1000 \
          --network=default \
          --target-tags=proxy \
          --quiet; then
          echo "!!! Error: Failed to create firewall rule for project $PROJECT_ID. Deleting project $PROJECT_ID and retrying."
          gcloud projects delete "$PROJECT_ID" --quiet
          exit 100
        fi

        # 5. Add IAM permission to allow default service account full control (roles/editor)
        SERVICE_ACCOUNT=$(gcloud config get-value account)
        echo "Adding 'roles/editor' permission for service account $SERVICE_ACCOUNT on project $PROJECT_ID"
        if ! gcloud projects add-iam-policy-binding "$PROJECT_ID" \
          --member="serviceAccount:$SERVICE_ACCOUNT" \
          --role="roles/editor" \
          --quiet; then
          echo "!!! Error: Failed to add IAM permission for project $PROJECT_ID. Deleting project $PROJECT_ID and retrying."
          gcloud projects delete "$PROJECT_ID" --quiet
          exit 100
        fi

        # 6. Create proxy instances
        INSTANCE_PIDS_FOR_PROJECT=()
        for j in $(seq 1 $((NUM_INSTANCES_PER_PROJECT / 2))); do
          for ZONE in "$ZONE_TOKYO" "$ZONE_OSAKA"; do
            ZONE_NAME=$(echo "$ZONE" | sed 's/asia-northeast1-a/tokyo/g; s/asia-northeast2-a/osaka/g')
            INSTANCE_NAME="proxy-${ZONE_NAME}-${j}"

            echo ">>> Creating instance $INSTANCE_NAME in zone $ZONE for project $PROJECT_ID..."

            gcloud compute instances create "$INSTANCE_NAME" \
              --zone="$ZONE" \
              --machine-type="e2-micro" \
              --image-family="debian-11" \
              --image-project="debian-cloud" \
              --tags=proxy \
              --metadata=startup-script-url="$SCRIPT_URL",PROXY_USER="$PROXY_USER",PROXY_PASS="$PROXY_PASS",PROXY_PORT="$PROXY_PORT",BOT_TOKEN="$BOT_TOKEN",USER_ID="$USER_ID" \
              --quiet &
            INSTANCE_PIDS_FOR_PROJECT+=("$!")
          done
        done

        # Wait for all instances within this project to complete creation
        for pid in "${INSTANCE_PIDS_FOR_PROJECT[@]}"; do
          wait "$pid" || echo "Warning: An instance in project $PROJECT_ID might not have been created successfully."
        done
        
        # NOTE: Telegram notification from the main script is removed here,
        # as each VM will now send its own proxy details via install_socks5_proxy()

        echo ">>> ✅ Project $PROJECT_ID done"
        exit 0
      ) & # Run the entire project creation block in a parallel subshell
      
      CURRENT_PROJECT_PID=$!
      
      wait "$CURRENT_PROJECT_PID"
      EXIT_CODE=$?

      if [ "$EXIT_CODE" -eq 0 ]; then
        SUCCESSFUL_PROJECT_COUNT=$((SUCCESSFUL_PROJECT_COUNT + 1))
        echo "Project created successfully: $SUCCESSFUL_PROJECT_COUNT / $NUM_PROJECTS_TO_CREATE"
      else
        echo "Attempt to create a project failed (Exit Code: $EXIT_CODE). Will try again if needed."
      fi

      if [ "$ATTEMPT_COUNT" -gt "$((NUM_PROJECTS_TO_CREATE * 5))" ]; then
        echo "!!! Warning: Too many attempts ($ATTEMPT_COUNT) to create projects without reaching the target. Stopping."
        break
      fi

      sleep 5
    done

    echo -e "\n=== Project creation completed. Total successful projects: $SUCCESSFUL_PROJECT_COUNT ==="
    echo -e "\nWaiting for all instances within successful projects to be ready (this happens asynchronously via startup scripts)..."

    # Note: Waiting for instances here only ensures the 'gcloud compute instances create' command was sent.
    # The actual startup script execution and proxy readiness is a separate process on each instance.
fi
