#!/bin/sh
set -e

echo "[acme-worker] Container started"

# Create passwd entry for current UID if missing (required for SSH)
if ! whoami >/dev/null 2>&1; then
  echo "acme:x:$(id -u):$(id -g):acme:/acme/home:/bin/sh" >> /etc/passwd
  echo "[acme-worker] Created passwd entry for UID $(id -u)"
fi

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

# Run crond with custom PID path for non-root
exec crond -n -s
