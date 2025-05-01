#!/bin/bash
set -euo pipefail

echo "=== init-startup.sh: starting at $(date -Is) ==="

# Mount persistent data disk
DISK_DEVICE="/dev/disk/by-id/google-flarum-data-disk"
MOUNT_POINT="/opt/flarum-data"
FS_TYPE="ext4"

if [ ! -d "$MOUNT_POINT" ]; then
  mkdir -p "$MOUNT_POINT"
  echo "ensured mount point directory: $MOUNT_POINT"
fi

# Format if not already formatted
if ! blkid "$DISK_DEVICE" >/dev/null; then
  mkfs.$FS_TYPE -F "$DISK_DEVICE"
  echo "disk formatted (if it was unformatted): $DISK_DEVICE"
fi

# Mount the disk
mount -o discard,defaults "$DISK_DEVICE" "$MOUNT_POINT"
echo "disk mounted at $MOUNT_POINT"

# Ensure it mounts on reboot
grep -q "^$DISK_DEVICE $MOUNT_POINT" /etc/fstab || echo "$DISK_DEVICE $MOUNT_POINT $FS_TYPE discard,defaults,nofail 0 2" >> /etc/fstab
grep -q "^$DISK_DEVICE $MOUNT_POINT" /etc/fstab && echo "fstab entry ensured for $DISK_DEVICE"

# Retrieve postboot script from instance metadata
echo "fetching postboot.sh from metadata"
curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/postboot-script \
  -o "$MOUNT_POINT/postboot.sh"
chmod +x "$MOUNT_POINT/postboot.sh"
echo "invoking postboot script"
cd "$MOUNT_POINT"
./postboot.sh && touch "$MOUNT_POINT/.postboot-done"
echo "postboot script completed"
