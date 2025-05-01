#!/bin/bash
set -euo pipefail

echo "=== postboot.sh: starting at $(date -Is) ==="

# Retry helper: retry a command up to 5 times with delay
retry() {
  local -r -a cmd=("$@")
  local -i max=5 count=1
  until "${cmd[@]}"; do
    if (( count == max )); then
      echo "❌ Retry failed after $count attempts: ${cmd[*]}" >&2
      exit 1
    fi
    echo "⚠️ Retry ${cmd[*]} (attempt $count/$max)" >&2
    ((count++)) && sleep 5
  done
}

# Wait for apt lock to clear
wait_for_apt() {
  while fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
     || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    echo "⏳ Waiting for apt lock..."
    sleep 5
  done
}

# Wait for a systemd service to become active
wait_for_service() {
  local svc="$1"
  local -i max=10 i=0
  until systemctl is-active --quiet "$svc" || (( i == max )); do
    echo "⏳ Waiting for $svc to start..."
    ((i++)) && sleep 3
  done
}

# Wait for systemd to be ready
for i in {1..60}; do
  STATUS=$(systemctl is-system-running || echo "starting")
  echo "↪ Status: $STATUS"
  if [[ "$STATUS" == "running" || "$STATUS" == "degraded" ]]; then
    echo "✔ System is ready (status: $STATUS)"
    break
  fi
  sleep 2
done

echo "Performing initial apt update"
wait_for_apt
retry apt-get update

echo "checking Docker installation"
# Install Docker, Compose, Git, curl, unzip if needed
if ! command -v docker &>/dev/null; then
  wait_for_apt
  retry apt-get install -y docker.io docker-compose git curl unzip

# Ensure the Docker daemon is enabled and running
  retry systemctl enable docker
  retry systemctl start docker
  wait_for_service docker
  echo "Docker installed/enabled and daemon started"
fi

echo "checking Google Cloud SDK installation"
# Install Google Cloud SDK if not already present
if ! command -v gcloud &>/dev/null; then
  wait_for_apt
  retry apt-get install -y apt-transport-https ca-certificates gnupg curl
  retry curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    | tee /etc/apt/sources.list.d/google-cloud-sdk.list
  retry apt-get install -y google-cloud-cli
  echo "Google Cloud SDK installed"
fi

echo "Retrieving secrets"
PROJECT_ID="flarum-oss-forum"
GITHUB_TOKEN=$(retry gcloud secrets versions access latest --secret=github-token --project=$PROJECT_ID)
CERTBOT_EMAIL=$(retry gcloud secrets versions access latest --secret=certbot-email --project=$PROJECT_ID)
FLARUM_DB_PASSWORD=$(retry gcloud secrets versions access latest --secret=flarum-db-password --project=$PROJECT_ID)
SMTP_USER=$(retry gcloud secrets versions access latest --secret=smtp-user --project=$PROJECT_ID)
SMTP_PASS=$(retry gcloud secrets versions access latest --secret=smtp-pass --project=$PROJECT_ID)
SMTP_MAIL_FROM=$(retry gcloud secrets versions access latest --secret=smtp-mail-from --project=$PROJECT_ID)
echo "secrets retrieved: GITHUB_TOKEN, CERTBOT_EMAIL, FLARUM_DB_PASSWORD, SMTP_USER, SMTP_PASS, SMTP_MAIL_FROM"

echo "cloning deployment repository if necessary"
if [ ! -d "flarum" ]; then
  retry git clone https://"$GITHUB_TOKEN"@github.com/ggrierson/comm-hub-flarum.git flarum
fi
cd flarum
echo "repository clone/setup complete"

echo "Templating environment"
cp .env.template .env
retry sed -i "s|{{DB_PASSWORD}}|$FLARUM_DB_PASSWORD|g" .env
retry sed -i "s|{{CERTBOT_EMAIL}}|$CERTBOT_EMAIL|g" .env
retry sed -i "s|{{SMTP_USER}}|$SMTP_USER|g" .env
retry sed -i "s|{{SMTP_PASS}}|$SMTP_PASS|g" .env
retry sed -i "s|{{SMTP_MAIL_FROM}}|$SMTP_MAIL_FROM|g" .env
echo "environment file templated"

echo "running docker-compose pull"
# Launch Flarum stack
retry docker-compose pull
retry docker-compose up -d
echo "docker-compose up complete"

echo "checking TLS certificate provisioning"
# Initial TLS certificate provisioning (if not already present)
if [ ! -f "./certs/live/$DOMAIN/fullchain.pem" ]; then
  echo "Provisioning Let's Encrypt certificate for $DOMAIN..."

  retry docker run --rm \
    -v flarum_certbot_www:/var/www/certbot \
    -v "$(pwd)/certs:/etc/letsencrypt" \
    certbot/certbot certonly \
    --webroot -w /var/www/certbot \
    --email "$CERTBOT_EMAIL" \
    -d "$DOMAIN" \
    --agree-tos --non-interactive
fi

echo "postboot.sh: complete at $(date -Is)"