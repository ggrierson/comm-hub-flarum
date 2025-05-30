#!/bin/bash
set -euo pipefail

# MARK: LOGGING SETUP
# Ensure we have a metadata fetch tool (curl or wget)
if command -v curl &>/dev/null; then
  FETCH="curl -fsSL"
elif command -v wget &>/dev/null; then
  FETCH="wget -qO-"
else
  apt-get update
  apt-get install -y curl
  FETCH="curl -fsSL"
fi

# Load logging functions from metadata
eval "$($FETCH -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/attributes/logging-lib)"
log_debug "✅ Logging functions loaded successfully"

## MARK: TERRAFORM ENV
# Safe initialization of Terraform-injected vars
GIT_BRANCH="${GIT_BRANCH:-}"
SUBDOMAIN="${SUBDOMAIN:-forum-hub.team-apps.net}"
LETSENCRYPT_ENV_STAGING="${LETSENCRYPT_ENV_STAGING:-false}"
CLEAN_UNUSED_CERTS="${CLEAN_UNUSED_CERTS:-false}"

# ✅ Diagnostic: Show active configuration
log_info "🌿 Terraform-injected config vars:"
log_info "  - GIT_BRANCH=$GIT_BRANCH"
log_info "  - SUBDOMAIN=$SUBDOMAIN"
log_info "  - LETSENCRYPT_ENV_STAGING=$LETSENCRYPT_ENV_STAGING"
log_info "  - CLEAN_UNUSED_CERTS=$CLEAN_UNUSED_CERTS"

# MARK: INITIAL BOOT LOGIC
# Optional marker logic: only skip heavy bootstrap tasks
MARKER=/opt/bootstrap/.postboot-done
if [[ -f "$MARKER" ]]; then
  log_info "⏭ postboot.sh: initial bootstrap previously completed — continuing with incremental logic"
  BOOTSTRAP_FIRST_RUN=false
else
  log_info "🚀 Running full bootstrap for the first time"
  touch "$MARKER"
  BOOTSTRAP_FIRST_RUN=true
fi

# ensure this script is deleted when it exits (even on error)
trap 'rm -f "$0"' EXIT

# Trap any error and print the failing line, command, and exit code
trap 'rc=$?; log_error "❌ ERROR in ${0##*/} at line ${LINENO}: \\"${BASH_COMMAND}\\" exited with $rc" >&2; exit $rc' ERR

log_info "=== ${0##*/}: starting at $(date -Is) ==="

# Retry helper: retry a command up to 5 times with delay
retry() {
  local -r -a cmd=("$@")
  local -i max=5 count=1
  until "${cmd[@]}"; do
    if (( count == max )); then
      log_error "❌ Retry failed after $count attempts: ${cmd[*]}" >&2
      exit 1
    fi
    log_warn "⚠️ Retry ${cmd[*]} (attempt $count/$max)" >&2
    ((count++)) && sleep 5
  done
}

# Wait for apt lock to clear
wait_for_apt() {
  log_info "⏳ Waiting for apt lock..."
  while fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
     || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    log_debug "⏳ Waiting for apt lock..."
    sleep 5
  done
}

# Wait for a systemd service to become active
wait_for_service() {
  local svc="$1"
  local -i max=10 i=0
  until systemctl is-active --quiet "$svc" || (( i == max )); do
    log_debug "⏳ Waiting for $svc to start..."
    ((i++)) && sleep 3
  done
}

log_debug "⏳ Waiting for systemd to be ready…"
for i in {1..10}; do
  if systemctl is-system-running --quiet; then
    log_info "✔ Systemd is ready"
    break
  fi
  log_info "  still starting (${i}/10)…"
  sleep 2
done

# Conditional logic for one-time bootstrap tasks
if [[ "$BOOTSTRAP_FIRST_RUN" == "true" ]]; then
  log_info "⚙️ Running one-time initialization logic (e.g., package installs, Docker setup)"
  # Place all logic that should only run on first boot here
  wait_for_apt
  retry apt-get update

  log_info "checking Docker installation"
  # Install Docker, Compose, Git, curl, unzip if needed
  if ! command -v docker &>/dev/null; then
    wait_for_apt
    retry apt-get install -y docker.io docker-compose git curl unzip
    retry systemctl enable docker
    retry systemctl start docker
    wait_for_service docker
    log_info "Docker installed/enabled and daemon started"
  fi

  log_info "checking Google Cloud SDK installation"
  # Install Google Cloud SDK if not already present
  if ! command -v gcloud &>/dev/null; then
    wait_for_apt
    retry apt-get install -y apt-transport-https ca-certificates gnupg curl
    retry curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
    log_info "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | tee /etc/apt/sources.list.d/google-cloud-sdk.list
    retry apt-get install -y google-cloud-cli
    log_info "Google Cloud SDK installed"
  fi
else
  log_info "🔁 Skipping one-time setup logic — already initialized"
fi

# MARK: SECRETS
PROJECT_ID="flarum-oss-forum"

log_info "Retrieving secrets"
GITHUB_TOKEN=$(retry gcloud secrets versions access latest --secret=github-token --project=$PROJECT_ID)
SECRET_CERTBOT_EMAIL=$(retry gcloud secrets versions access latest --secret=certbot-email --project=$PROJECT_ID)
FLARUM_DB_PASSWORD=$(retry gcloud secrets versions access latest --secret=flarum-db-password --project=$PROJECT_ID)
FLARUM_ADMIN_PASSWORD=$(retry gcloud secrets versions access latest --secret=flarum-admin-password --project=$PROJECT_ID)
MARIADB_ROOT_PASSWORD=$(retry gcloud secrets versions access latest --secret=flarum-maria-root-password --project=$PROJECT_ID)
SMTP_USER=$(retry gcloud secrets versions access latest --secret=smtp-user --project=$PROJECT_ID)
SMTP_PASS=$(retry gcloud secrets versions access latest --secret=smtp-pass --project=$PROJECT_ID)
SMTP_MAIL_FROM=$(retry gcloud secrets versions access latest --secret=smtp-mail-from --project=$PROJECT_ID)

## MARK: GIT
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

log_info "🕵️‍♂️ .netrc written to /root/.netrc"
[ "$LEVEL_NUM" -ge 3 ] && log_debug "machine github.com\nlogin ggrierson\npassword ********"

# Define where the app code lives on the boot disk
REPO_DIR="/opt/flarum"
# APP_DIR="/$REPO_DIR/flarum"
# Ensure code directory exists and switch into it
mkdir -p "$REPO_DIR"
cd "$REPO_DIR"

log_info "Changed directory to $REPO_DIR"
log_info "🕵️‍♂️ Whoami: $(whoami), HOME: $HOME"
log_info "🕵️‍♂️ Testing git ls-remote…"
GIT_TERMINAL_PROMPT=0 retry git ls-remote https://github.com/ggrierson/comm-hub-flarum.git
log_info "🕵️‍♂️ Contents of $(pwd):"
ls -lA

log_info "🔁 Checking if repo already exists at $REPO_DIR"
if [[ ! -d "$REPO_DIR/.git" ]]; then
  log_info "📥 Cloning repository to $REPO_DIR"
  retry git clone https://github.com/ggrierson/comm-hub-flarum.git "$REPO_DIR"
else
  log_info "✔ Repo already exists"
fi

if [[ -n "${GIT_BRANCH:-}" ]]; then
  log_info "🔁 Switching to branch: $GIT_BRANCH"
  retry git fetch origin
  retry git checkout "$GIT_BRANCH"
  retry git pull origin "$GIT_BRANCH"
else
  log_info "ℹ️ GIT_BRANCH not set — staying on current/default branch"
fi

# ✅ Log current git branch
log_info "📍 Active Git branch: $(git rev-parse --abbrev-ref HEAD)"

rm -f /root/.netrc

## MARK: CREATE ENV
## CREATE ENV --------------------------------
# Template environment file
log_info "Templating .flarum.env"
cp .flarum.env.template .flarum.env

#Helper function - escape &, /, \ in the value before sed
escape_sed() {
  echo "$1" | sed -e 's/[&/\]/\\&/g'
}

# Escape all values for sed safety
SUB_ESCAPED=$(escape_sed "$SUBDOMAIN")
DB_PASS_ESCAPED=$(escape_sed "$FLARUM_DB_PASSWORD")
MARIADB_ROOT_PASSWORD_ESCAPED=$(escape_sed "$MARIADB_ROOT_PASSWORD")
ADMIN_PASS_ESCAPED=$(escape_sed "$FLARUM_ADMIN_PASSWORD")
ADMIN_EMAIL_ESCAPED=$(escape_sed "$SECRET_CERTBOT_EMAIL")
SMTP_USER_ESCAPED=$(escape_sed "$SMTP_USER")
SMTP_PASS_ESCAPED=$(escape_sed "$SMTP_PASS")
SMTP_MAIL_FROM_ESCAPED=$(escape_sed "$SMTP_MAIL_FROM")

# Substitute values into .flarum.env
retry sed -i "s|{{FORUM_SUBDOMAIN}}|$SUB_ESCAPED|g" .flarum.env
retry sed -i "s|{{DB_PASSWORD}}|$DB_PASS_ESCAPED|g" .flarum.env
retry sed -i "s|{{DB_ROOT_PASSWORD}}|$MARIADB_ROOT_PASSWORD_ESCAPED|g" .flarum.env
retry sed -i "s|{{ADMIN_PASSWORD}}|$ADMIN_PASS_ESCAPED|g" .flarum.env
retry sed -i "s|{{ADMIN_EMAIL}}|$ADMIN_EMAIL_ESCAPED|g" .flarum.env
retry sed -i "s|{{SMTP_USER}}|$SMTP_USER_ESCAPED|g" .flarum.env
retry sed -i "s|{{SMTP_PASS}}|$SMTP_PASS_ESCAPED|g" .flarum.env
retry sed -i "s|{{SMTP_MAIL_FROM}}|$SMTP_MAIL_FROM_ESCAPED|g" .flarum.env
log_info ".flarum.env file templated"

DEPLOY_USER="$(logname 2>/dev/null || who | awk '{print $1}' | head -n1)"
log_info "🔐 Securing .flarum.env permissions"
if id "$DEPLOY_USER" &>/dev/null; then
  log_info "🔐 Making .flarum.env readable by group: $DEPLOY_USER"
  chmod 640 .flarum.env
  chown root:"$DEPLOY_USER" .flarum.env
else
  log_warn "⚠ Could not determine deploy user, defaulting to root:root"
  chmod 640 .flarum.env
  chown root:root .flarum.env
fi
log_info "✅ Permissions set to 640 (readable by root and group)"

## MARK: INITIAL CERTS
## CERTIFICATES --------------------------------
CERTS_DIR="/opt/flarum-data/certs"
LIVE_BASE="$CERTS_DIR/live"
BOOTSTRAP_DIR="$CERTS_DIR/bootstrap/$SUBDOMAIN"
CURRENT_LINK="$CERTS_DIR/current"
CERT_PATH="$CURRENT_LINK/fullchain.pem"

mkdir -p "$CERTS_DIR"
chmod 755 "$CERTS_DIR"

# Ensure ACME challenge webroot is writable and exists
log_info "➤ Creating webroot for HTTP-01 challenge"
mkdir -p "$CERTS_DIR/.well-known/acme-challenge"
chmod 755 "$CERTS_DIR/.well-known" "$CERTS_DIR/.well-known/acme-challenge"

# Ensure a cert exists at CURRENT_LINK for nginx to start
if [[ ! -f "$CERT_PATH" ]]; then
  log_info "📭 No cert found, generating temporary self-signed cert for NGINX"
  mkdir -p "$BOOTSTRAP_DIR"
  openssl req -x509 -nodes -days 2 -newkey rsa:2048 \
    -keyout "$BOOTSTRAP_DIR/privkey.pem" \
    -out "$BOOTSTRAP_DIR/fullchain.pem" \
    -subj "/CN=${SUBDOMAIN}"
  ln -sfn "$(realpath --relative-to="$CERTS_DIR" "$BOOTSTRAP_DIR")" "$CURRENT_LINK"
else
  log_info "✔ Cert already exists at $CERT_PATH, skipping bootstrap cert generation"
fi
log_info "📝 Symlink status:"
ls -l "$CURRENT_LINK" || log_error "❌ $CURRENT_LINK is missing or broken"


# Wait until .flarum.env is fully written and contains the required value
wait_for_env_var() {
  local file="$1"
  local var="$2"
  local max_attempts=10
  local attempt=1

  until grep -q "^${var}=" "$file"; do
    if (( attempt == max_attempts )); then
      log_error "❌ $var not found in $file after $attempt attempts" >&2
      exit 1
    fi
    log_debug "⏳ Waiting for $var to appear in $file… ($attempt/$max_attempts)"
    ((attempt++)) && sleep 1
  done
}
wait_for_env_var .flarum.env "FLARUM_ADMIN_PASS"
log_debug "📄 Final contents of .flarum.env:"
[ "$LEVEL_NUM" -ge 3 ] && cat .flarum.env

## MARK: DOCKER
log_info "🧭 Running Docker Compose"
retry docker-compose pull
retry docker-compose up -d
log_info "Docker Compose operations complete"

log_info "📝 Current symlinked dir:"
ls -l "$CURRENT_LINK" || log_error "❌ host certs not found"


log_info "📝 Nginx container sees:"
docker exec flarum_nginx ls -l /etc/letsencrypt/current || log_error "❌ Nginx cert path invalid"

log_info "🧪 Checking ACME webroot"
# one-off endpoint check to see if nginx is serving the right directory for certbot
log_info "🧪 Verifying ACME webroot inside the running Nginx container…"
docker exec flarum_nginx ls -l /var/www/certbot/.well-known/acme-challenge || \
  log_error "❌ webroot not visible in nginx!"

log_info "🧪 HTTP challenge healthcheck"
log_info test > "$CERTS_DIR/.well-known/acme-challenge/healthcheck"
curl -v http://localhost/.well-known/acme-challenge/healthcheck || log_error "❌ Healthcheck failed. Nginx still not serving the file!"

## MARK: NEW CERTS
log_debug "⏳ Waiting for nginx to serve challenge"
for i in {1..30}; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/.well-known/acme-challenge/test-path || log_info "")
  if log_info "$STATUS" | grep -qE '^[234]'; then
    log_info "🟢 NGINX is up and reachable"
    break
  fi
  log_debug "⏳ Waiting for NGINX to start… ($i/30)"
  sleep 2
done

NEEDS_NEW_CERT=false
ISSUER=$(openssl x509 -in "$CERT_PATH" -noout -issuer 2>/dev/null || log_info "")
SUBJECT=$(openssl x509 -in "$CERT_PATH" -noout -subject 2>/dev/null || log_info "")
IS_SELF_SIGNED=$(openssl x509 -in "$CERT_PATH" -noout -issuer -subject 2>/dev/null | \
  awk -F'= ' '/issuer=/{issuer=$NF} /subject=/{subject=$NF} END{print issuer==subject}')

if [[ -z "$ISSUER" ]]; then
  log_info "📭 No certificate found — issuing new one"
  NEEDS_NEW_CERT=true
elif [[ "$IS_SELF_SIGNED" == "1" ]]; then
  log_info "📭 Self-signed certificate detected — replacing with real certificate"
  NEEDS_NEW_CERT=true
elif [[ "$LETSENCRYPT_ENV_STAGING" == "false" ]]; then
  if log_info "$ISSUER" | grep -q "(STAGING)"; then
    log_info "📭 Detected staging cert but production is enabled — replacing with production cert"
    NEEDS_NEW_CERT=true
  else
    log_info "✅ Production certificate is already in place — no action needed"
  fi
else
  log_info "✅ Valid certificate present (issuer: $ISSUER) — no replacement needed"
fi

if [[ "$NEEDS_NEW_CERT" == "false" ]]; then
  log_info "✅ Valid cert found — issuer: $ISSUER"
else
  log_info "🚀 Requesting new certificate"
  ACME_SERVER=""
  if [[ "${LETSENCRYPT_ENV_STAGING,,}" == "true" ]]; then
    ACME_SERVER="--server https://acme-staging-v02.api.letsencrypt.org/directory"
    log_info "🧪 Using Let’s Encrypt STAGING environment"
  else
    log_info "✅ Using Let’s Encrypt PRODUCTION environment"
  fi

  FORCE_RENEWAL=""
  if [[ "$ISSUER" == *"(STAGING)"* || "$IS_SELF_SIGNED" == "1" ]]; then
    log_info "🔁 Forcing renewal to replace staging/self-signed cert with production"
    FORCE_RENEWAL="--force-renewal"
  fi

  retry docker run --rm \
    -v "$CERTS_DIR":/var/www/certbot \
    -v "$CERTS_DIR":/etc/letsencrypt \
    certbot/certbot certonly \
      --config-dir /etc/letsencrypt \
      --work-dir /var/www/certbot \
      --logs-dir /var/www/certbot \
      --webroot -w /var/www/certbot \
      --email "$SECRET_CERTBOT_EMAIL" \
      -d "$SUBDOMAIN" \
      --agree-tos --non-interactive \
      $ACME_SERVER $FORCE_RENEWAL

  NEW_LIVE=$(find "$LIVE_BASE" -maxdepth 1 -type d -name "$SUBDOMAIN*" | sort | tail -n1)
  if [[ -n "$NEW_LIVE" ]]; then
    ln -sfn "$(realpath --relative-to="$CERTS_DIR" "$NEW_LIVE")" "$CURRENT_LINK"
    log_info "🔗 Updated symlink: $CURRENT_LINK → $(readlink -f "$CURRENT_LINK")"
    log_info "🔁 Reloading NGINX to apply new certificate"
    docker-compose restart nginx
  else
    log_error "❌ No new live cert dir found after issuance"
    exit 1
  fi

  # 🔗 Log current symlink used by NGINX
  if [[ -L "$CURRENT_LINK" ]]; then
    log_info "🔗 Current symlink: $CURRENT_LINK -> $(readlink -f "$CURRENT_LINK")"
  else
    log_warn "⚠️  $CURRENT_LINK is not a symlink or is broken"
  fi

  log_info "🧹 Scanning unused cert dirs..."
  shopt -s nullglob
  for d in "$LIVE_BASE/${SUBDOMAIN}-"*; do
    config_file="$CERTS_DIR/renewal/$(basename "$d").conf"
    if [[ ! -f "$config_file" ]]; then
      log_warn "⚠️ Unreferenced dir: $d"
      [[ "$CLEAN_UNUSED_CERTS" == "true" ]] && rm -rf "$d" && log_info "🗑️ Deleted $d"
    fi
  done
  shopt -u nullglob
fi

log_info "🧾 Renewal configs:"
ls -l "$CERTS_DIR/renewal" || log_error "❌ None found"

log_info "🔐 Tightening /opt/flarum-data permissions to 700"
chmod 700 /opt/flarum-data
chown root:root /opt/flarum-data

touch "$MARKER"

log_info "postboot.sh: complete at $(date -Is)"
