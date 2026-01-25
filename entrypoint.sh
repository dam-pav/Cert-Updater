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

# Create crontab directory and file for busybox crond
# Busybox crond expects files named after the user running the jobs

# Get current username (might be dynamically created)
CRON_USER=$(whoami 2>/dev/null || echo "root")
CRONTAB_FILE="/acme/crontabs/$CRON_USER"

# Create default crontab only if it doesn't exist
if [ ! -f "$CRONTAB_FILE" ]; then
  cat > "$CRONTAB_FILE" <<EOF
# Run certificate sync on the 1st of each month at 3:00 AM
0 3 1 * * /acme/bin/sync-certs.sh >> /var/log/cron/acme.log 2>&1
EOF
  echo "[acme-worker] Created default crontab for user: $CRON_USER"
else
  echo "[acme-worker] Using existing crontab for user: $CRON_USER"
fi

# Run busybox crond with custom crontab directory (foreground mode keeps container alive)
exec crond -f -l 6 -c /acme/crontabs
