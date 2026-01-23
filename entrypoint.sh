#!/bin/sh
set -e

echo "[acme-worker] Container started"

# Sanity check
if [ ! -f /acme/config/domains.yml ]; then
  echo "[acme-worker] ERROR: /acme/config/domains.yml not found"
  exit 1
fi

echo "[acme-worker] Running initial certificate sync"
/acme/bin/sync-certs.sh

echo "[acme-worker] Initial sync complete"
echo "[acme-worker] Starting cron"

# Install cron job for the current user
echo '0 3 1 * * /usr/local/bin/acme.sh --cron --home /acme/state >> /var/log/cron/acme.log 2>&1' | crontab -

exec crond -f -l 8
