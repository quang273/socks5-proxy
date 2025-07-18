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

    # --- DEBUGGING LINE ---
    echo "DEBUG: Initial counts - SUCCESSFUL_PROJECT_COUNT=$SUCCESSFUL_PROJECT_COUNT, NUM_PROJECTS_TO_CREATE=$NUM_PROJECTS_TO_CREATE"
    # --- END DEBUGGING LINE ---

    # Loop until the desired number of projects are successfully created
    while (( SUCCESSFUL_PROJECT_COUNT < NUM_PROJECTS_TO_CREATE )); do
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
          gcloud projects delete "$PROJECT_ID" --quiet 2>/dev/null || true # Attempt to clean up, ignore errors
          exit 100 # Exit subshell with a non-zero code to signal failure
        fi

        # 2. Link the billing account
        BILLING_ACCOUNT=$(gcloud beta billing accounts list --format="value(ACCOUNT_ID)" | head -n 1)
        if [ -z "$BILLING_ACCOUNT" ]; then
          echo "!!! Error: No billing account found. Please ensure a billing account is linked to your GCP account."
          echo "Deleting project '$PROJECT_ID' due to billing account issue and retrying."
          gcloud projects delete "$PROJECT_ID" --quiet 2>/dev/null || true
          exit 100
        fi
        echo "Linking project '$PROJECT_ID' to billing account: '$BILLING_ACCOUNT'..."
        if ! gcloud beta billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"; then
          echo "!!! Error: Failed to link project '$PROJECT_ID' to billing account. This might be a permission issue or a temporary problem."
          echo "Deleting project '$PROJECT_ID' and retrying."
          gcloud projects delete "$PROJECT_ID" --quiet 2>/dev/null || true
          exit 100
        fi
        echo "Project '$PROJECT_ID' linked to billing account."

        # 3. Enable Compute Engine API
        echo "Enabling Compute Engine API for project '$PROJECT_ID'..."
        if ! gcloud services enable compute.googleapis.com --project="$PROJECT_ID"; then
          echo "!!! Error: Failed to enable Compute Engine API for project '$PROJECT_ID'. This is critical for VM creation."
          echo "Deleting project '$PROJECT_ID' and retrying."
          gcloud projects delete "$PROJECT_ID" --quiet 2>/dev/null || true
          exit 100
        fi
        echo "Compute Engine API enabled for project '$PROJECT_ID'."

        # 4. Set current project (for subsequent commands within this subshell)
        echo "Setting gcloud project to '$PROJECT_ID' for current operations..."
        gcloud config set project "$PROJECT_ID"

        # 5. Add firewall rule to allow proxy ports
        echo "Adding 'allow-proxy' firewall rule for project '$PROJECT_ID'..."
        if ! gcloud compute firewall-rules create allow-proxy --project="$PROJECT_ID" \
          --allow=tcp:$PROXY_PORT,tcp:1080,tcp:443 \
          --direction=INGRESS \
          --priority=1000 \
          --network=default \
          --target-tags=proxy \
          --description="Allow SOCKS5 proxy (port $PROXY_PORT), HTTP proxy (port 1080) and HTTPS (port 443) traffic." \
          --quiet; then
          echo "!!! Error: Failed to create firewall rule for project '$PROJECT_ID'. This could block proxy traffic."
          echo "Deleting project '$PROJECT_ID' and retrying."
          gcloud projects delete "$PROJECT_ID" --quiet 2>/dev/null || true
          exit 100
        fi
        echo "Firewall rule 'allow-proxy' created."

        # 6. Add IAM permission to allow the default service account full control (roles/editor)
        # This is for Cloud Shell's service account to manage resources within the new project.
        SERVICE_ACCOUNT=$(gcloud config get-value account)
        echo "Adding 'roles/editor' permission for service account '$SERVICE_ACCOUNT' on project '$PROJECT_ID'..."
        if ! gcloud projects add-iam-policy-binding "$PROJECT_ID" \
          --member="serviceAccount:$SERVICE_ACCOUNT" \
          --role="roles/editor" \
          --quiet; then
          echo "!!! Error: Failed to add IAM permission for project '$PROJECT_ID'. This might prevent instance creation."
          echo "Deleting project '$PROJECT_ID' and retrying."
          gcloud projects delete "$PROJECT_ID" --quiet 2>/dev/null || true
          exit 100
        fi
        echo "IAM permission 'roles/editor' granted to '$SERVICE_ACCOUNT'."

        # 7. Create proxy instances
        INSTANCE_PIDS_FOR_PROJECT=()
        for j in $(seq 1 $((NUM_INSTANCES_PER_PROJECT / 2))); do
          for ZONE in "$ZONE_TOKYO" "$ZONE_OSAKA"; do
            ZONE_NAME=$(echo "$ZONE" | sed 's/asia-northeast1-a/tokyo/g; s/asia-northeast2-a/osaka/g')
            INSTANCE_NAME="proxy-${ZONE_NAME}-${j}"

            echo ">>> Creating instance '$INSTANCE_NAME' in zone '$ZONE' for project '$PROJECT_ID'..."

            # The --metadata=startup-script-url points to this very script on GitHub,
            # so the VM will download and execute the 'install_socks5_proxy' function.
            gcloud compute instances create "$INSTANCE_NAME" \
              --project="$PROJECT_ID" \
              --zone="$ZONE" \
              --machine-type="e2-micro" \
              --image-family="debian-11" \
              --image-project="debian-cloud" \
              --tags=proxy \
              --metadata=startup-script-url="$SCRIPT_URL",PROXY_USER="$PROXY_USER",PROXY_PASS="$PROXY_PASS",PROXY_PORT="$PROXY_PORT",BOT_TOKEN="$BOT_TOKEN",USER_ID="$USER_ID" \
              --quiet & # Run instance creation in background
            INSTANCE_PIDS_FOR_PROJECT+=("$!") # Store PID to wait for later
          done
        done

        # Wait for all instance creation commands within this project to complete
        echo "Waiting for all instance creation commands in project '$PROJECT_ID' to finish..."
        for pid in "${INSTANCE_PIDS_FOR_PROJECT[@]}"; do
          wait "$pid" || echo "Warning: An instance creation command in project '$PROJECT_ID' might have failed."
        done
        
        echo ">>> ✅ Project '$PROJECT_ID' setup complete."
        exit 0 # Exit subshell with success
      ) & # Run the entire project creation block in a parallel subshell
      
      CURRENT_PROJECT_PID=$! # Get PID of the subshell
      
      wait "$CURRENT_PROJECT_PID" # Wait for the current project creation subshell to finish
      EXIT_CODE=$?

      if [ "$EXIT_CODE" -eq 0 ]; then
        SUCCESSFUL_PROJECT_COUNT=$((SUCCESSFUL_PROJECT_COUNT + 1))
        echo "Project created successfully: $SUCCESSFUL_PROJECT_COUNT / $NUM_PROJECTS_TO_CREATE"
      else
        echo "Attempt to create a project failed (Exit Code: $EXIT_CODE). Will try again if needed."
      fi

      # Prevent infinite loops in case of persistent errors
      if [ "$ATTEMPT_COUNT" -gt "$((NUM_PROJECTS_TO_CREATE * 5))" ]; then
        echo "!!! Warning: Too many attempts ($ATTEMPT_COUNT) to create projects without reaching the target. Stopping project creation loop."
        break
      fi

      sleep 5 # Short delay before next attempt
    done
    set -e # Re-enable set -e after the main loop

    echo -e "\n=== Project creation completed. Total successful projects: $SUCCESSFUL_PROJECT_COUNT ==="
    echo -e "\nWaiting for all instances within successful projects to be ready (this happens asynchronously via startup scripts)..."
    echo "This might take a few minutes as each VM downloads and runs the proxy installation script."
    echo "You can check the progress and public IPs using: 'gcloud compute instances list --filter=\"tags:proxy\"'"

else # This branch executes if not in Cloud Shell, implying it's a GCE VM (running as startup script)
    # Check if the metadata for startup-script-url exists, which indicates it's a startup script.
    # This check helps to prevent accidental execution of proxy installation if the script is run directly on a VM,
    # but not as a startup script.
    # If this is a real GCE VM provisioned by our script, it will have startup-script-url.
    STARTUP_SCRIPT_METADATA=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/startup-script-url 2>/dev/null || true)
    
    if [ -n "$STARTUP_SCRIPT_METADATA" ]; then
        echo "Script detected running on a Google Cloud Compute Engine instance (as startup script)."
        install_socks5_proxy
        exit 0 # Exit after installing proxy if on VM
    else
        echo "Error: Script not detected as running in Cloud Shell or as a GCE startup script."
        echo "This script is designed to be executed in Google Cloud Shell for project/instance creation,"
        echo "or as a startup script on a Google Compute Engine VM for proxy installation."
        exit 1 # Indicate an error if context is unclear
    fi
fi
