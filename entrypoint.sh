#!/bin/sh
set -e

log() {
  echo "[acme-worker] $(date -u +"%Y-%m-%dT%H:%M:%SZ") $*"
}

validate_interval() {
  case "$1" in
    ''|*[!0-9]*)
      return 1
      ;;
    *)
      [ "$1" -gt 0 ]
      ;;
  esac
}

SYNC_INTERVAL_SECONDS=${SYNC_INTERVAL_SECONDS:-86400}

if ! validate_interval "$SYNC_INTERVAL_SECONDS"; then
  echo "[acme-worker] ERROR: SYNC_INTERVAL_SECONDS must be a positive integer, got '$SYNC_INTERVAL_SECONDS'" >&2
  exit 1
fi

stop_requested=0

handle_shutdown() {
  stop_requested=1
  log "Shutdown signal received, stopping sync loop"
}

trap 'handle_shutdown' TERM INT

log "Container started"

# Create passwd entry for current UID if missing (required for SSH)
if ! whoami >/dev/null 2>&1; then
  echo "acme:x:$(id -u):$(id -g):acme:/acme/home:/bin/sh" >> /etc/passwd
  log "Created passwd entry for UID $(id -u)"
fi

# Sanity check
if [ ! -f /acme/config/settings.yml ]; then
  echo "[acme-worker] ERROR: /acme/config/settings.yml not found" >&2
  exit 1
fi

log "Running initial certificate sync"
/acme/bin/sync-certs.sh

log "Initial sync complete"
log "Starting internal sync loop (interval: ${SYNC_INTERVAL_SECONDS}s)"

while [ "$stop_requested" -eq 0 ]; do
  log "Sleeping for ${SYNC_INTERVAL_SECONDS}s before next sync"
  sleep "$SYNC_INTERVAL_SECONDS" &
  sleep_pid=$!

  wait "$sleep_pid" || true

  if [ "$stop_requested" -ne 0 ]; then
    break
  fi

  log "Running scheduled certificate sync"
  if /acme/bin/sync-certs.sh; then
    log "Scheduled sync completed"
  else
    log "Scheduled sync failed, will retry after ${SYNC_INTERVAL_SECONDS}s"
  fi
done

log "Sync loop stopped"
