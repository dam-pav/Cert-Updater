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

get_acme_next_renewal_time() {
  domain=$1

  for conf in "/acme/state/${domain}_ecc/${domain}.conf" "/acme/state/${domain}/${domain}.conf"; do
    if [ -r "$conf" ]; then
      next_renewal=$(sed -n "s/^Le_NextRenewTime=['\"]\{0,1\}\([0-9][0-9]*\)['\"]\{0,1\}$/\1/p" "$conf" | head -n 1)
      if [ -n "$next_renewal" ]; then
        echo "$next_renewal"
        return 0
      fi
    fi
  done

  return 0
}

refresh_sync_interval() {
  fallback_interval=$1
  earliest_renewal=
  now=$(date -u +%s)
  domain_count=$(yq e '.domains // [] | length' /acme/config/settings.yml)

  i=0
  while [ "$i" -lt "$domain_count" ]; do
    domain=$(yq e ".domains[$i].name // \"\"" /acme/config/settings.yml)
    if [ -n "$domain" ]; then
      next_renewal=$(get_acme_next_renewal_time "$domain")
      if validate_interval "$next_renewal"; then
        if [ -z "$earliest_renewal" ] || [ "$next_renewal" -lt "$earliest_renewal" ]; then
          earliest_renewal=$next_renewal
        fi
      else
        log "No ACME renewal time found for $domain; using fallback interval if needed"
      fi
    fi
    i=$((i + 1))
  done

  if [ -z "$earliest_renewal" ]; then
    SYNC_INTERVAL_SECONDS=$fallback_interval
    log "No ACME renewal times found; next sync interval: ${SYNC_INTERVAL_SECONDS}s"
    return 0
  fi

  if [ "$earliest_renewal" -le "$now" ]; then
    SYNC_INTERVAL_SECONDS=1
  else
    SYNC_INTERVAL_SECONDS=$((earliest_renewal - now))
  fi

  log "Next sync interval set from earliest ACME renewal time: ${SYNC_INTERVAL_SECONDS}s"
}

SYNC_INTERVAL_SECONDS=${SYNC_INTERVAL_SECONDS:-86400}

if ! validate_interval "$SYNC_INTERVAL_SECONDS"; then
  echo "[acme-worker] ERROR: SYNC_INTERVAL_SECONDS must be a positive integer, got '$SYNC_INTERVAL_SECONDS'" >&2
  exit 1
fi

FALLBACK_SYNC_INTERVAL_SECONDS=$SYNC_INTERVAL_SECONDS

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
refresh_sync_interval "$FALLBACK_SYNC_INTERVAL_SECONDS"
log "Starting internal sync loop (fallback interval: $(format_duration "$SYNC_INTERVAL_SECONDS"))"

while [ "$stop_requested" -eq 0 ]; do
  log "Sleeping for $(format_duration "$SYNC_INTERVAL_SECONDS") before next sync"
  sleep "$SYNC_INTERVAL_SECONDS" &
  sleep_pid=$!

  wait "$sleep_pid" || true

  if [ "$stop_requested" -ne 0 ]; then
    break
  fi

  log "Running scheduled certificate sync"
  if /acme/bin/sync-certs.sh; then
    sync_result=0
  else
    sync_result=$?
  fi

  refresh_sync_interval "$FALLBACK_SYNC_INTERVAL_SECONDS"

  if [ "$sync_result" -eq 0 ]; then
    log "Scheduled sync completed"
  else
    log "Scheduled sync failed, will retry after $(format_duration "$SYNC_INTERVAL_SECONDS")"
  fi
done

log "Sync loop stopped"
