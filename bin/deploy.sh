#!/bin/sh
set -e

DOMAIN="$1"
HOST_NAME="$2"
HOST_URL="$3"
DEST="$4"
RELOAD_CMD="$5"
TRANSFER="${6:-scp}"  # default to scp

SRC="/cert-updater/export/${DOMAIN}"

# Create host-specific directory for known_hosts
mkdir -p "/cert-updater/home/.ssh-runtime/${HOST_NAME}"

# SSH options for non-interactive use
# Use host-specific known_hosts file
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 -o UserKnownHostsFile=/cert-updater/home/.ssh-runtime/${HOST_NAME}/known_hosts"

echo "Deploying $DOMAIN to $HOST_NAME ($HOST_URL:$DEST) via $TRANSFER"

ssh $SSH_OPTS "$HOST_URL" "mkdir -p '$DEST'"

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
