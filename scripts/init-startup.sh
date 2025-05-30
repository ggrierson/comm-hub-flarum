#!/bin/bash
set -euo pipefail

# Lightweight logging function without any calls to VM metadata.
log_info()  { echo "[INFO]  $1"; }

# Trap any error and print the failing line, command, and exit code
trap 'rc=$?; echo "❌ ERROR in ${0##*/} at line ${LINENO}: \\"${BASH_COMMAND}\\" exited with $rc" >&2; exit $rc' ERR

log_info "=== ${0##*/}: starting at $(date -Is) ==="

# Mount persistent data disk
DISK_DEVICE="/dev/disk/by-id/google-flarum-data-disk"
MOUNT_POINT="/opt/flarum-data"
FS_TYPE="ext4"

if [ ! -d "$MOUNT_POINT" ]; then
  mkdir -p "$MOUNT_POINT"
  log_info "Created mount point: $MOUNT_POINT"
fi

# Format if not already formatted
if ! blkid "$DISK_DEVICE" &>/dev/null; then
  mkfs.$FS_TYPE -F "$DISK_DEVICE"
  log_info "Formatted disk: $DISK_DEVICE"
fi

# Mount the disk
if ! mountpoint -q "$MOUNT_POINT"; then
  mount -o discard,defaults "$DISK_DEVICE" "$MOUNT_POINT"
  log_info "✅ Mounted $DISK_DEVICE at $MOUNT_POINT"
else
  log_info "🔁 $MOUNT_POINT already mounted — skipping"
fi

# Ensure it mounts on reboot
grep -q "^$DISK_DEVICE $MOUNT_POINT" /etc/fstab || echo "$DISK_DEVICE $MOUNT_POINT $FS_TYPE discard,defaults,nofail 0 2" >> /etc/fstab
log_info "fstab entry ensured for $DISK_DEVICE"

# -------------------------------------------------------------------
# Seed all of our persistent paths on the data disk (idempotent!)
log_info "Seeding persistent data dirs on $MOUNT_POINT"
mkdir -p "$MOUNT_POINT"/{mariadb,assets,extensions,storage,certs}
chmod 755    "$MOUNT_POINT"
chown -R 991:991 "$MOUNT_POINT/assets"
chown -R 991:991 "$MOUNT_POINT/extensions"
log_info "  → created: $MOUNT_POINT/mariadb, assets, extensions, storage, certs"
# -------------------------------------------------------------------

log_info "Setting up bootstrap directory on VM boot disk"
BOOT_DIR="/opt/bootstrap"
mkdir -p "$BOOT_DIR"
log_info "Ensured bootstrap directory: $BOOT_DIR"

# nuke any ancient scripts so we start from a blank slate
rm -f "$BOOT_DIR/bootstrap.sh" "$BOOT_DIR/postboot.sh"

log_info "Creating bootstrap script."

# Bootstrap to fetch and run postboot.sh
cat << 'EOF' > "$BOOT_DIR/bootstrap.sh"
#!/bin/bash
set -euo pipefail

log_info() { echo "[INFO] $1"; }

log_info "Running postboot bootstrap script"

# install minimal fetch tool
if command -v curl &>/dev/null; then
  FETCH="curl -fsSL"
elif command -v wget &>/dev/null; then
  FETCH="wget -qO-"
else
  apt-get update
  apt-get install -y curl
  FETCH="curl -fsSL"
fi

# Fetch and export GCE metadata vars
log_info "📦 Fetching metadata vars into env"
for var in GIT_BRANCH SUBDOMAIN LETSENCRYPT_ENV_STAGING CLEAN_UNUSED_CERTS LOGLEVEL; do
  value=$($FETCH -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$var" || true)
  export "$var"="$value"
done
log_info "🔎 LETSENCRYPT_ENV_STAGING fetched as: '$LETSENCRYPT_ENV_STAGING'"

# Optional: diagnostic
env | grep -E 'GIT_BRANCH|SUBDOMAIN|LETSENCRYPT|CLEAN_UNUSED|LOGLEVEL'

BOOT_DIR="/opt/bootstrap"
# fetch and execute postboot
$FETCH -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/postboot-script \
  > "$BOOT_DIR/postboot.sh"
chmod +x "$BOOT_DIR/postboot.sh"
bash "$BOOT_DIR/postboot.sh"
touch "$BOOT_DIR/.postboot-done"
EOF

bash "$BOOT_DIR/bootstrap.sh"
log_info "=== init-startup.sh: postboot bootstrap complete at $(date -Is) ==="
exit 0
