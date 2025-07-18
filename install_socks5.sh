#!/bin/bash

# Exit immediately if a command *not related to project creation* fails.
# For project creation errors, we handle them specifically to retry the loop.
set -e

# === CONFIGURATION ===
PROJECT_PREFIX="proxyproj"
NUM_PROJECTS_TO_CREATE=3 # Target number of successful projects to create
NUM_INSTANCES=8          # Total instances per project (4 Tokyo, 4 Osaka)
ZONE_TOKYO="asia-northeast1-a"
ZONE_OSAKA="asia-northeast2-a"
SCRIPT_URL="https://raw.githubusercontent.com/quang273/socks5-proxy/main/install_socks5.sh" # URL for the SOCKS5 installation script

# Proxy metadata (read from environment variables or use defaults)
# This allows sensitive info to be passed via environment variables from the calling script
PROXY_USER="${PROXY_USER:-khoitran}"
PROXY_PASS="${PROXY_PASS:-khoi1}"
PROXY_PORT="${PROXY_PORT:-8888}"

# Telegram Bot (read from environment variables)
BOT_TOKEN="${BOT_TOKEN:-}"
USER_ID="${USER_ID:-}"

if [ -z "$BOT_TOKEN" ] || [ -z "$USER_ID" ]; then
    echo "Warning: BOT_TOKEN or USER_ID not set. Telegram bot functionality may not work."
fi

# === Create Projects and Proxies ===
# Array to store PIDs of successfully initiated project creation processes
PROJECT_PIDS=()
SUCCESSFUL_PROJECT_COUNT=0
ATTEMPT_COUNT=0

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
    # This role is broad but ensures the script has necessary permissions.
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
    for j in $(seq 1 $((NUM_INSTANCES / 2))); do
      for ZONE in "$ZONE_TOKYO" "$ZONE_OSAKA"; do
        # Improve instance naming for easier identification
        # e.g., proxy-tokyo-1, proxy-osaka-1
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
        INSTANCE_PIDS_FOR_PROJECT+=("$!") # Store PID of the instance creation process
      done
    done

    # Wait for all instances within this project to complete creation
    for pid in "${INSTANCE_PIDS_FOR_PROJECT[@]}"; do
      wait "$pid" || echo "Warning: An instance in project $PROJECT_ID might not have been created successfully."
    done
    
    echo ">>> ✅ Project $PROJECT_ID done"
    exit 0 # Return 0 if the project was created completely and successfully
  ) & # Run the entire project creation block in a parallel subshell
  
  CURRENT_PROJECT_PID=$! # Get the PID of the newly launched subshell
  
  # Wait for the subshell to complete and check its exit code
  wait "$CURRENT_PROJECT_PID"
  EXIT_CODE=$?

  if [ "$EXIT_CODE" -eq 0 ]; then
    SUCCESSFUL_PROJECT_COUNT=$((SUCCESSFUL_PROJECT_COUNT + 1))
    echo "Project created successfully: $SUCCESSFUL_PROJECT_COUNT / $NUM_PROJECTS_TO_CREATE"
  else
    echo "Attempt to create a project failed (Exit Code: $EXIT_CODE). Will try again if needed."
  fi

  # Prevent an infinite loop if there's a persistent error
  if [ "$ATTEMPT_COUNT" -gt "$((NUM_PROJECTS_TO_CREATE * 5))" ]; then # Try a maximum of 5 times the target count
    echo "!!! Warning: Too many attempts ($ATTEMPT_COUNT) to create projects without reaching the target. Stopping."
    break
  fi

  # Pause briefly between attempts to avoid rate limiting or overloading
  sleep 5 

done

echo -e "\n=== Project creation completed. Total successful projects: $SUCCESSFUL_PROJECT_COUNT ==="
echo -e "\nWaiting for all instances within successful projects to be ready (this happens asynchronously via startup scripts)..."

# Note: Waiting for instances here only ensures the 'gcloud compute instances create' command was sent.
# The actual startup script execution and proxy readiness is a separate process on each instance.
