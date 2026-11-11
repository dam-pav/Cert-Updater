#!/bin/sh
set -e

. /cert-updater/bin/deployment-state.sh

DOMAIN="$1"
HOST_NAME="$2"
HOST_URL="$3"
DEST="$4"
RELOAD_CMD="$5"
TRANSFER="${6:-scp}"  # default to scp

SRC="/cert-updater/export/${DOMAIN}"
PENDING="/cert-updater/state/.${DOMAIN}.deploy-pending"
touch "$PENDING"

# Create host-specific directory for known_hosts
mkdir -p "/cert-updater/home/.ssh-runtime/${HOST_NAME}"

# SSH options for non-interactive use
# Use host-specific known_hosts file
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 -o UserKnownHostsFile=/cert-updater/home/.ssh-runtime/${HOST_NAME}/known_hosts"

echo "Deploying $DOMAIN to $HOST_NAME ($HOST_URL:$DEST) via $TRANSFER"

ssh $SSH_OPTS "$HOST_URL" "mkdir -p $(deployment_quote "$DEST")"

case "$TRANSFER" in
  rsync)
    rsync -az -e "ssh $SSH_OPTS" "$SRC/" "$HOST_URL:$DEST/"
    ;;
  scp|*)
    # Use -O for legacy SCP protocol (doesn't require sftp-server on remote)
    scp -O $SSH_OPTS "$SRC/key.pem" "$SRC/cert.pem" "$HOST_URL:$DEST/"
    ;;
esac

ssh $SSH_OPTS "$HOST_URL" "$RELOAD_CMD"

# Read the installed file back; SSH connectivity and a successful copy alone
# are not proof that the expected certificate reached the configured target.
remote_cert=$(mktemp)
trap 'rm -f "$remote_cert"' EXIT HUP INT TERM
read_remote_certificate "$HOST_NAME" "$HOST_URL" "$DEST" "$remote_cert"
local_fingerprint=$(certificate_fingerprint "$SRC/cert.pem")
remote_fingerprint=$(certificate_fingerprint "$remote_cert")
if [ -z "$local_fingerprint" ] || [ "$local_fingerprint" != "$remote_fingerprint" ] || \
   ! cmp -s "$SRC/cert.pem" "$remote_cert"; then
  echo "ERROR: remote certificate does not match the exported certificate for $DOMAIN" >&2
  exit 1
fi
record_deployment "$DOMAIN" "$HOST_URL" "$DEST" "$RELOAD_CMD" "$local_fingerprint" "$SRC/cert.pem"
rm -f "$PENDING"
echo "Verified deployment of $DOMAIN"
