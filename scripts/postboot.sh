#!/bin/bash
set -euo pipefail

# DEBUG: turn on command-by-command tracing
set -x

# if we've already run once, bail out immediately
MARKER=/opt/bootstrap/.postboot-done
if [[ -f "$MARKER" ]]; then
  echo "⏭ postboot.sh: already completed, skipping."
  exit 0
fi

# ensure this script is deleted when it exits (even on error)
trap 'rm -f "$0"' EXIT

# Trap any error and print the failing line, command, and exit code
trap 'rc=$?; echo "❌ ERROR in ${0##*/} at line ${LINENO}: \\"${BASH_COMMAND}\\" exited with $rc" >&2; exit $rc' ERR

echo "=== ${0##*/}: starting at $(date -Is) ==="

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

echo "⏳ Waiting for systemd to be ready…"
for i in {1..10}; do
  if systemctl is-system-running --quiet; then
    echo "✔ Systemd is ready"
    break
  fi
  echo "  still starting (${i}/10)…"
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
  retry curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | tee /etc/apt/sources.list.d/google-cloud-sdk.list
  retry apt-get install -y google-cloud-cli
  echo "Google Cloud SDK installed"
fi

echo "Retrieving secrets"
PROJECT_ID="flarum-oss-forum"
GITHUB_TOKEN=$(retry gcloud secrets versions access latest --secret=github-token --project=$PROJECT_ID)
SUBDOMAIN="forum-hub.team-apps.net"
CERTBOT_EMAIL=$(retry gcloud secrets versions access latest --secret=certbot-email --project=$PROJECT_ID)
FLARUM_DB_PASSWORD=$(retry gcloud secrets versions access latest --secret=flarum-db-password --project=$PROJECT_ID)
FLARUM_ADMIN_PASSWORD=$(retry gcloud secrets versions access latest --secret=flarum-admin-password --project=$PROJECT_ID)
SMTP_USER=$(retry gcloud secrets versions access latest --secret=smtp-user --project=$PROJECT_ID)
SMTP_PASS=$(retry gcloud secrets versions access latest --secret=smtp-pass --project=$PROJECT_ID)
SMTP_MAIL_FROM=$(retry gcloud secrets versions access latest --secret=smtp-mail-from --project=$PROJECT_ID)
echo "secrets retrieved: GITHUB_TOKEN, CERTBOT_EMAIL, FLARUM_DB_PASSWORD, FLARUM_ADMIN_PASSWORD, SMTP_USER, SMTP_PASS, SMTP_MAIL_FROM"

## CLONE REPO --------------------------------
# Configure .netrc for Git authentication
export HOME=/root
export GIT_TERMINAL_PROMPT=0
cat << EOF > /root/.netrc
machine github.com
login ggrierson
password $GITHUB_TOKEN
EOF
chmod 600 /root/.netrc

echo "🕵️‍♂️ .netrc contents:"
sed -e 's/.*/&/' /root/.netrc

# Define where the app code lives on the boot disk
REPO_DIR="/opt/flarum"
# APP_DIR="/$REPO_DIR/flarum"
# Ensure code directory exists and switch into it
mkdir -p "$REPO_DIR"
cd "$REPO_DIR"

echo "Changed directory to $REPO_DIR"
echo "🕵️‍♂️ Whoami: $(whoami), HOME: $HOME"
echo "🕵️‍♂️ Testing git ls-remote…"
GIT_TERMINAL_PROMPT=0 retry git ls-remote https://github.com/ggrierson/comm-hub-flarum.git
echo "🕵️‍♂️ Contents of $(pwd):"
ls -lA

echo "cloning deployment repository if necessary"
if [ ! -d "$REPO_DIR/.git" ]; then
  retry git clone https://github.com/ggrierson/comm-hub-flarum.git "$REPO_DIR"
fi
echo "repository clone/setup complete"
rm -f /root/.netrc

## CREATE ENV --------------------------------
# Template environment file
echo "Templating environment"
cp .env.template .env
retry sed -i "s|{{SUBDOMAIN}}|${SUBDOMAIN//&/\\&}|g" .env
retry sed -i "s|{{DB_PASSWORD}}|${FLARUM_DB_PASSWORD//&/\\&}|g" .env
retry sed -i "s|{{ADMIN_PASSWORD}}|${FLARUM_ADMIN_PASSWORD//&/\\&}|g" .env
retry sed -i "s|{{ADMIN_EMAIL}}|${CERTBOT_EMAIL//&/\\&}|g" .env
retry sed -i "s|{{CERTBOT_EMAIL}}|${CERTBOT_EMAIL//&/\\&}|g" .env
retry sed -i "s|{{SMTP_USER}}|${SMTP_USER//&/\\&}|g" .env
retry sed -i "s|{{SMTP_PASS}}|${SMTP_PASS//&/\\&}|g" .env
retry sed -i "s|{{SMTP_MAIL_FROM}}|${SMTP_MAIL_FROM//&/\\&}|g" .env
echo "environment file templated"

## CERTIFICATES --------------------------------
# Generate a temporary self-signed cert so Nginx can start
CERTS_DIR="/opt/flarum-data/certs"
mkdir -p "$CERTS_DIR/live/$SUBDOMAIN"
chmod 755 "$CERTS_DIR"
openssl req -x509 -nodes -days 2 -newkey rsa:2048 \
  -keyout $CERTS_DIR/live/$SUBDOMAIN/privkey.pem \
  -out $CERTS_DIR/live/$SUBDOMAIN/fullchain.pem \
  -subj "/CN=${SUBDOMAIN}"

echo "📝 Diagnostic: listing bootstrap certs directory on host:"
ls -l $CERTS_DIR/live/"$SUBDOMAIN"

# Ensure ACME challenge webroot is writable and exists
echo "➤ Creating webroot for HTTP-01 challenge"
mkdir -p "$CERTS_DIR/.well-known/acme-challenge"
chmod 755 "$CERTS_DIR/.well-known" "$CERTS_DIR/.well-known/acme-challenge"

## DOCKER --------------------------------
# Run Docker Compose
echo "🧭 PWD before docker-compose: $(pwd)"
# echo "Listing nginx.conf and certs:"
# ls -l nginx.conf certs

# Run Docker Compose operations
retry docker-compose pull
retry docker-compose up -d

echo "Docker Compose operations complete"

echo "📝 Host certs dir:"
ls -l $CERTS_DIR/live/"$SUBDOMAIN" || echo "❌ host certs not found"

echo "📝 Nginx sees certs:"
docker exec flarum_nginx ls -l /etc/letsencrypt/live/"$SUBDOMAIN" \
  || echo "❌ nginx container or path not found"



# one-off endpoint check to see if nginx is serving the right directory for certbot
echo "🧪 Verifying ACME webroot inside the running Nginx container…"
docker exec flarum_nginx ls -l /var/www/certbot/.well-known/acme-challenge || \
  echo "❌ webroot not visible in nginx!"

echo "🧪 Curling the healthcheck…"
echo test > /opt/flarum-data/certs/.well-known/acme-challenge/healthcheck
curl -v http://localhost/.well-known/acme-challenge/healthcheck || \
  echo "❌ Nginx still not serving the file!"

## NEW CERTIFICATES ----------------------------
# Wait until NGINX is serving the HTTP-01 challenge endpoint
echo "Waiting for NGINX to serve HTTP challenge"
for i in {1..30}; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/.well-known/acme-challenge/test-path || echo "")
  if echo "$STATUS" | grep -qE '^[234]'; then
    echo "🟢 NGINX is up and reachable"
    break
  fi
  echo "⏳ Waiting for NGINX to start... ($i)"
  sleep 2
done

# Remove the bootstrap self-signed certificates so Certbot will request a real one
echo "🧹 Removing bootstrap certificates for $SUBDOMAIN"
rm -rf "$CERTS_DIR/live/$SUBDOMAIN"

# Request the Let’s Encrypt certificate
echo "Requesting real certificate for $SUBDOMAIN"
# Determine Let’s Encrypt server endpoint (staging/prod)
if [[ "${LETSENCRYPT_ENV_STAGING,,}" == "true" ]]; then
  ACME_SERVER="--server https://acme-staging-v02.api.letsencrypt.org/directory"
  echo "🧪 Using Let’s Encrypt STAGING environment"
else
  ACME_SERVER=""
  echo "✅ Using Let’s Encrypt PRODUCTION environment"
fi

retry docker run --rm \
  -v "$CERTS_DIR":/var/www/certbot \
  -v "$CERTS_DIR":/etc/letsencrypt \
  certbot/certbot certonly \
    --webroot -w /var/www/certbot \
    --email "$CERTBOT_EMAIL" \
    -d "$SUBDOMAIN" \
    --agree-tos --non-interactive \
    $ACME_SERVER

echo "Reloading NGINX with real certificate"
docker-compose restart nginx

echo "postboot.sh: complete at $(date -Is)"
