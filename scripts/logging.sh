#!/bin/bash
# === LOGGING LIBRARY ===
# Use the injected LOGLEVEL if available, fallback only if unset
LOGLEVEL="${LOGLEVEL:-info}"
echo "LOGLEVEL=$LOGLEVEL"

# Map log level to numeric severity
case "$LOGLEVEL" in
  debug) LEVEL_NUM=3 ;;
  info)  LEVEL_NUM=2 ;;
  warn)  LEVEL_NUM=1 ;;
  error) LEVEL_NUM=0 ;;
  *)     LEVEL_NUM=2 ;;  # Fallback to 'info'
esac

# Logging functions
log_debug() { [ "$LEVEL_NUM" -ge 3 ] && echo "[DEBUG] $1"; }
log_info()  { [ "$LEVEL_NUM" -ge 2 ] && echo "[INFO]  $1"; }
log_warn()  { [ "$LEVEL_NUM" -ge 1 ] && echo "[WARN]  $1" >&2; }
log_error() { echo "[ERROR] $1" >&2; }

# Enable shell tracing in debug mode
[ "$LEVEL_NUM" -ge 3 ] && set -x
