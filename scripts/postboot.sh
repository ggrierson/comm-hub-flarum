#!/bin/bash
set -euo pipefail

# Retry helper: retry a command up to 5 times with delay
retry() {
  local -r -a cmd=("$@")
  local -i max=5
  local -i count=1
  until "${cmd[@]}"; do
    if (( count == max )); then
      echo "❌ Retry failed after $count attempts: ${cmd[*]}" >&2
      return 1
    fi
    echo "⚠️ Retry ${cmd[*]} (attempt $count/$max)" >&2
    ((count++))
    sleep 5
  done
}

# Wait for package manager lock to clear
wait_for_apt() {
  while fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
     || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    echo "⏳ Waiting for apt lock to clear..."
    sleep 5
  done
}

# Wait for a systemd service to become active
wait_for_service() {
  local svc="$1"
  local -i max=10
  local -i i=0
  until systemctl is-active --quiet "$svc" || (( i == max )); do
    echo "⏳ Waiting for $svc to start..."
    ((i++))
    sleep 3
  done
}

echo "fetching postboot.sh from metadata"
wait_for_apt
retry curl -fsSL -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/postboot-script \
  -o "$MOUNT_POINT/postboot.sh"
chmod +x "$MOUNT_POINT/postboot.sh"
echo "postboot.sh fetched and made executable"
