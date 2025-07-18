#!/bin/bash

# === CONFIGURATION ===
PROJECT_PREFIX="proxyproj"
NUM_PROJECTS=3
NUM_INSTANCES=8
ZONE_TOKYO="asia-northeast1-a"
ZONE_OSAKA="asia-northeast2-a"
SCRIPT_URL="https://raw.githubusercontent.com/quang273/socks5-proxy/main/install_socks5.sh"

# Proxy metadata
PROXY_USER="khoitran"
PROXY_PASS="khoi1"
PROXY_PORT="8888"

# Telegram Bot
BOT_TOKEN="7938057750:AAG8LSryy716gmDaoP36IjpdCXtycHDtKKM"
USER_ID="1053423800"

# === Create Projects and Proxies ===
PROJECT_IDS=()

for i in $(seq 1 $NUM_PROJECTS); do
  (
    RAW_ID="${PROJECT_PREFIX}-${RANDOM}"
    PROJECT_ID="$RAW_ID"
    PROJECT_IDS+=("$PROJECT_ID")

    echo -e "\n>>> [${i}] Creating project: $PROJECT_ID"
    gcloud projects create "$PROJECT_ID" --name="$PROJECT_ID"

    BILLING_ACCOUNT=$(gcloud beta billing accounts list --format="value(ACCOUNT_ID)" | head -n 1)
    gcloud beta billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"

    gcloud services enable compute.googleapis.com --project="$PROJECT_ID"
    gcloud config set project "$PROJECT_ID"

    for j in $(seq 1 $((NUM_INSTANCES / 2))); do
      for ZONE in "$ZONE_TOKYO" "$ZONE_OSAKA"; do
        INSTANCE_NAME="proxy-${ZONE##*-}-${j}"

        echo ">>> Creating instance $INSTANCE_NAME in zone $ZONE..."

        gcloud compute instances create "$INSTANCE_NAME" \
          --zone="$ZONE" \
          --machine-type="e2-micro" \
          --image-family="debian-11" \
          --image-project="debian-cloud" \
          --metadata=startup-script-url="$SCRIPT_URL",PROXY_USER="$PROXY_USER",PROXY_PASS="$PROXY_PASS",PROXY_PORT="$PROXY_PORT",BOT_TOKEN="$BOT_TOKEN",USER_ID="$USER_ID" \
          --quiet &
      done
    done

    wait
    echo ">>> ✅ Project $PROJECT_ID done"
  ) &
done

wait
echo -e "\n✅ All projects and proxies created successfully."
