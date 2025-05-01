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

echo "Creating postboot bootstrap script"

# Bootstrap to fetch and run postboot.sh
cat << 'EOF' > "/opt/flarum-data/bootstrap.sh"
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

# fetch and execute postboot
$FETCH -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/postboot-script \
  > "/opt/flarum-data/postboot.sh"
chmod +x "/opt/flarum-data/postboot.sh"
bash "/opt/flarum-data/postboot.sh"
touch "/opt/flarum-data/.postboot-done"
EOF

bash "/opt/flarum-data/bootstrap.sh"
echo "=== init-startup.sh: postboot bootstrap complete at $(date -Is) ===""