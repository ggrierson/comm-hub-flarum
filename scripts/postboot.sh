#!/bin/bash
set -euo pipefail
echo "=== postboot.sh: starting at $(date -Is) ==="

echo "checking Docker installation"
# Install Docker, Compose, Git, curl, unzip if needed

if ! command -v docker &>/dev/null; then
  apt-get update && apt-get install -y docker.io docker-compose git curl unzip

  # Ensure the Docker daemon is enabled and running
  systemctl enable docker
  systemctl start docker
  echo "Docker installed/enabled and daemon started"
fi

echo "checking Google Cloud SDK installation"
# Install Google Cloud SDK if not already present
if ! command -v gcloud &>/dev/null; then
  apt-get update && apt-get install -y apt-transport-https ca-certificates gnupg curl
  curl https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    | tee /etc/apt/sources.list.d/google-cloud-sdk.list
  apt-get update && apt-get install -y google-cloud-cli
  echo "Google Cloud SDK installed"
fi


# Example: Get secrets from Google Secret Manager
# Assumes gcloud is authenticated via default service account
PROJECT_ID="flarum-oss-forum"
GITHUB_TOKEN=$(gcloud secrets versions access latest --secret=github-token --project=$PROJECT_ID)
CERTBOT_EMAIL=$(gcloud secrets versions access latest --secret=certbot-email --project=$PROJECT_ID)
FLARUM_DB_PASSWORD=$(gcloud secrets versions access latest --secret=flarum-db-password --project=$PROJECT_ID)
SMTP_USER=$(gcloud secrets versions access latest --secret=smtp-user --project=$PROJECT_ID)
SMTP_PASS=$(gcloud secrets versions access latest --secret=smtp-pass --project=$PROJECT_ID)
SMTP_MAIL_FROM=$(gcloud secrets versions access latest --secret=smtp-mail-from --project=$PROJECT_ID)
echo "secrets retrieved: GITHUB_TOKEN, CERTBOT_EMAIL, FLARUM_DB_PASSWORD, SMTP_USER, SMTP_PASS, SMTP_MAIL_FROM"

echo "cloning deployment repository if necessary"
# Clone the deployment repo if needed (into current directory)
if [ ! -d ".git" ]; then
  git clone https://"$GITHUB_TOKEN"@github.com/ggrierson/comm-hub-flarum.git .
fi
echo "repository clone/setup complete"

# Inject secrets into .env from template
cp .env.template .env
sed -i "s|{{DB_PASSWORD}}|$FLARUM_DB_PASSWORD|g" .env
sed -i "s|{{CERTBOT_EMAIL}}|$CERTBOT_EMAIL|g" .env
sed -i "s|{{SMTP_USER}}|$SMTP_USER|g" .env
sed -i "s|{{SMTP_PASS}}|$SMTP_PASS|g" .env
sed -i "s|{{SMTP_MAIL_FROM}}|$SMTP_MAIL_FROM|g" .env
echo "environment file templated"

echo "running docker-compose pull"
# Launch Flarum stack
docker-compose pull
docker-compose up -d
echo "docker-compose up complete"

echo "checking TLS certificate provisioning"
# Initial TLS certificate provisioning (if not already present)
if [ ! -f "./certs/live/$DOMAIN/fullchain.pem" ]; then
  echo "Provisioning Let's Encrypt certificate for $DOMAIN..."

  docker run --rm \
    -v flarum_certbot_www:/var/www/certbot \
    -v "$(pwd)/certs:/etc/letsencrypt" \
    certbot/certbot certonly \
    --webroot -w /var/www/certbot \
    --email "$CERTBOT_EMAIL" \
    -d "$DOMAIN" \
    --agree-tos --non-interactive
fi
echo "postboot.sh: complete at $(date -Is)"
