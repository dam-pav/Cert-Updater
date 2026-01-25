#!/bin/sh
set -e

DOMAIN="$1"
HOST_URL="$2"
DEST="$3"
RELOAD_CMD="$4"
TRANSFER="${5:-scp}"  # default to scp

SRC="/acme/export/${DOMAIN}"

# SSH options for non-interactive use
# Use separate writable location for known_hosts since .ssh may be read-only
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 -o UserKnownHostsFile=/acme/home/.ssh-runtime/known_hosts"

echo "Deploying $DOMAIN to $HOST_URL:$DEST (via $TRANSFER)"

ssh $SSH_OPTS "$HOST_URL" "mkdir -p '$DEST'"

case "$TRANSFER" in
  rsync)
    rsync -az -e "ssh $SSH_OPTS" "$SRC/" "$HOST_URL:$DEST/"
    ;;
  scp|*)
    scp $SSH_OPTS "$SRC/key.pem" "$SRC/cert.pem" "$HOST_URL:$DEST/"
    ;;
esac

ssh $SSH_OPTS "$HOST_URL" "$RELOAD_CMD"
