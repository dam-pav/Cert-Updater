#!/bin/sh
set -e

. /cert-updater/bin/renewal-schedule.sh

log() {
  echo "[cert-updater] $(date -u +"%Y-%m-%dT%H:%M:%SZ") $*"
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

format_duration() {
  total_seconds=$1
  days=$((total_seconds / 86400))
  remainder=$((total_seconds % 86400))
  hours=$((remainder / 3600))
  remainder=$((remainder % 3600))
  minutes=$((remainder / 60))
  seconds=$((remainder % 60))

  echo "${days}d ${hours}h ${minutes}m ${seconds}s"
}

get_certificate_expiry_epoch() {
  for check_cert in \
    "/cert-updater/state/${1}_ecc/${1}.cer" \
    "/cert-updater/state/${1}_ecc/fullchain.cer" \
    "/cert-updater/state/${1}/${1}.cer" \
    "/cert-updater/state/${1}/fullchain.cer" \
    "/cert-updater/export/${1}/cert.pem"; do
    check_expiry=$(certificate_expiry "$check_cert" || true)
    if [ -n "$check_expiry" ]; then
      date -u -d "$(printf '%s' "$check_expiry" | sed 's/T/ /; s/Z$//')" +%s 2>/dev/null && return 0
    fi
  done
  return 0
}

refresh_sync_interval() {
  fallback_interval=$1
  earliest_check=
  now=$(date -u +%s)
  load_renewal_margin /cert-updater/config/settings.yml || return 1
  domain_count=$(yq e '.domains // [] | length' /cert-updater/config/settings.yml)

  i=0
  while [ "$i" -lt "$domain_count" ]; do
    domain=$(yq e ".domains[$i].name // \"\"" /cert-updater/config/settings.yml)
    expiry_epoch=$(get_certificate_expiry_epoch "$domain")
    if validate_interval "$expiry_epoch"; then
      next_check=$(next_check_time "$expiry_epoch" "$now" "$fallback_interval")
    else
      next_check=$((now + fallback_interval))
      log "No certificate expiry found for $domain; using fallback check interval"
    fi
    if [ -z "$earliest_check" ] || [ "$next_check" -lt "$earliest_check" ]; then
      earliest_check=$next_check
    fi
    i=$((i + 1))
  done

  if [ -n "$earliest_check" ]; then
    SYNC_INTERVAL_SECONDS=$((earliest_check - now))
  else
    SYNC_INTERVAL_SECONDS=$fallback_interval
  fi
  log "Next certificate check in ${SYNC_INTERVAL_SECONDS}s (expiry margin: ${renewal_margin_days} days; acme.sh decides renewal eligibility)"
}

SYNC_INTERVAL_SECONDS=${SYNC_INTERVAL_SECONDS:-86400}

if ! validate_interval "$SYNC_INTERVAL_SECONDS"; then
      echo "[cert-updater] ERROR: SYNC_INTERVAL_SECONDS must be a positive integer, got '$SYNC_INTERVAL_SECONDS'" >&2
  exit 1
fi

export FALLBACK_SYNC_INTERVAL_SECONDS=$SYNC_INTERVAL_SECONDS

stop_requested=0
force_sync_requested=0
sleep_pid=""

handle_shutdown() {
  stop_requested=1
  log "Shutdown signal received, stopping sync loop"
  if [ -n "$sleep_pid" ] && kill -0 "$sleep_pid" 2>/dev/null; then
    kill "$sleep_pid" 2>/dev/null || true
  fi
  if [ -n "$SETTINGS_API_PID" ] && kill -0 "$SETTINGS_API_PID" 2>/dev/null; then
    kill "$SETTINGS_API_PID" 2>/dev/null
    log "Settings API server stopped"
  fi
}

handle_force_sync() {
  force_sync_requested=1
  log "Manual sync requested"
  if [ -n "$sleep_pid" ] && kill -0 "$sleep_pid" 2>/dev/null; then
    kill "$sleep_pid" 2>/dev/null || true
  fi
}

trap 'handle_shutdown' TERM INT
trap 'handle_force_sync' USR1

log "Container started"

# Start settings API server in background
SETTINGS_PATH=/cert-updater/config/settings.yml SETTINGS_API_PORT=8081 python3 /cert-updater/bin/settings-api.py &
SETTINGS_API_PID=$!
log "Settings API server started (PID $SETTINGS_API_PID)"

# Create passwd entry for current UID if missing (required for SSH)
if ! whoami >/dev/null 2>&1; then
  echo "cert-updater:x:$(id -u):$(id -g):cert-updater:/cert-updater/home:/bin/sh" >> /etc/passwd
  log "Created passwd entry for UID $(id -u)"
fi

# Sanity check
if [ ! -f /cert-updater/config/settings.yml ]; then
  echo "[cert-updater] ERROR: /cert-updater/config/settings.yml not found" >&2
  exit 1
fi

load_renewal_margin /cert-updater/config/settings.yml

log "Running initial certificate sync"
/cert-updater/bin/sync-certs.sh

log "Initial sync complete"
refresh_sync_interval "$FALLBACK_SYNC_INTERVAL_SECONDS"
log "Starting internal sync loop (fallback interval: $(format_duration "$FALLBACK_SYNC_INTERVAL_SECONDS"))"

while [ "$stop_requested" -eq 0 ]; do
  if [ "$force_sync_requested" -eq 0 ]; then
    log "Sleeping for $(format_duration "$SYNC_INTERVAL_SECONDS") before next sync"
    sleep "$SYNC_INTERVAL_SECONDS" &
    sleep_pid=$!

    wait "$sleep_pid" || true
    sleep_pid=""
  fi

  if [ "$stop_requested" -ne 0 ]; then
    break
  fi

  if [ "$force_sync_requested" -eq 1 ]; then
    sync_label="Manual"
  else
    sync_label="Scheduled"
  fi
  force_sync_requested=0

  log "Running ${sync_label} certificate sync"
  if /cert-updater/bin/sync-certs.sh; then
    sync_result=0
  else
    sync_result=$?
  fi

  refresh_sync_interval "$FALLBACK_SYNC_INTERVAL_SECONDS"

  if [ "$sync_result" -eq 0 ]; then
    log "${sync_label} sync completed"
  else
    log "${sync_label} sync failed, will retry after $(format_duration "$SYNC_INTERVAL_SECONDS")"
  fi
done

log "Sync loop stopped"
