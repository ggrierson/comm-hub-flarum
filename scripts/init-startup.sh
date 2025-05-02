#!/bin/bash
set -euo pipefail

echo "=== init-startup.sh: starting at $(date -Is) ==="

# Mount persistent data disk
DISK_DEVICE="/dev/disk/by-id/google-flarum-data-disk"
MOUNT_POINT="/opt/flarum-data"
FS_TYPE="ext4"

if [ ! -d "$MOUNT_POINT" ]; then
  mkdir -p "$MOUNT_POINT"
  echo "Created mount point: $MOUNT_POINT"
fi

# Format if not already formatted
if ! blkid "$DISK_DEVICE" &>/dev/null; then
  mkfs.$FS_TYPE -F "$DISK_DEVICE"
  echo "Formatted disk: $DISK_DEVICE"
fi

# Mount the disk
mount -o discard,defaults "$DISK_DEVICE" "$MOUNT_POINT"
echo "Mounted disk at $MOUNT_POINT"

# Ensure it mounts on reboot
grep -q "^$DISK_DEVICE $MOUNT_POINT" /etc/fstab || echo "$DISK_DEVICE $MOUNT_POINT $FS_TYPE discard,defaults,nofail 0 2" >> /etc/fstab
echo "fstab entry ensured for $DISK_DEVICE"

echo "Setting up code directory on VM boot disk"
BOOT_DIR="/opt/flarum"
mkdir -p "$BOOT_DIR"
echo "Ensured code directory: $BOOT_DIR"

echo "Creating postboot bootstrap script in $BOOT_DIR"

# Bootstrap to fetch and run postboot.sh
cat << 'EOF' > "$BOOT_DIR/bootstrap.sh"
#!/bin/bash
set -euo pipefail

echo "Running postboot bootstrap script"

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

BOOT_DIR="/opt/flarum"
# fetch and execute postboot
$FETCH -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/postboot-script \
  > "$BOOT_DIR/postboot.sh"
chmod +x "$BOOT_DIR/postboot.sh"
bash "$BOOT_DIR/postboot.sh"
touch "$BOOT_DIR/.postboot-done"
EOF

bash "$BOOT_DIR/bootstrap.sh"
echo "=== init-startup.sh: postboot bootstrap complete at $(date -Is) ==="