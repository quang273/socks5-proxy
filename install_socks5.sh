#!/bin/bash

# === CONFIGURATION ===
PROJECT_PREFIX="proxyproj"
NUM_PROJECTS=3
NUM_INSTANCES=8
ZONE_TOKYO="asia-northeast1-a"
ZONE_OSAKA="asia-northeast2-a"
SCRIPT_URL="https://raw.githubusercontent.com/quang273/socks5-proxy/main/install_socks5.sh"

# === Proxy Info ===
export PROXY_USER="soncoi"
export PROXY_PASS="zxcv123"
export PROXY_PORT="8888"

# === Telegram Bot ===
export BOT_TOKEN="8002752987:AAGiuvuaiOAHr8UF1XCK5sFkqRH4n7bwcDQ"
export USER_ID="6456880948"

# === Create Projects ===
PROJECT_IDS=()
for i in $(seq 1 $NUM_PROJECTS); do
    RAW_ID="${PROJECT_PREFIX}-${RANDOM}"
    PROJECT_ID="$RAW_ID"
    PROJECT_IDS+=("$PROJECT_ID")
    echo -e "\n>>> [${i}] Creating project: $PROJECT_ID"
    gcloud projects create "$PROJECT_ID" --name="$PROJECT_ID"
    BILLING_ACCOUNT=$(gcloud beta billing accounts list --format="value(ACCOUNT_ID)" | head -n 1)
    gcloud beta billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"
    gcloud services enable compute.googleapis.com --project="$PROJECT_ID"
done

# === Create VMs ===
for PROJECT_ID in "${PROJECT_IDS[@]}"; do
    echo -e "\n>>> [Deploying SOCKS5] Project: $PROJECT_ID"
    gcloud config set project "$PROJECT_ID"

    for i in $(seq 1 $NUM_INSTANCES); do
        ZONE=$([[ $i -le 4 ]] && echo "$ZONE_TOKYO" || echo "$ZONE_OSAKA")
        gcloud compute instances create "proxy-socks5-$i" \
            --zone="$ZONE" \
            --machine-type=e2-micro \
            --image-family=debian-11 \
            --image-project=debian-cloud \
            --metadata=startup-script-url="$SCRIPT_URL" \
            --metadata=PROXY_USER=$PROXY_USER,PROXY_PASS=$PROXY_PASS,PROXY_PORT=$PROXY_PORT,BOT_TOKEN=$BOT_TOKEN,USER_ID=$USER_ID \
            --tags=proxy \
            --quiet &
    done
    wait
done
