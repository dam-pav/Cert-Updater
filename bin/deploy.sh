#!/bin/sh
set -e

DOMAIN="$1"
HOST_URL="$2"
DEST="$3"
RELOAD_CMD="$4"

SRC="/acme/export/${DOMAIN}"

# SSH options for non-interactive use
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10"

echo "Deploying $DOMAIN to $HOST_URL:$DEST"

ssh $SSH_OPTS "$HOST_URL" "mkdir -p '$DEST'"
rsync -az -e "ssh $SSH_OPTS" "$SRC/" "$HOST_URL:$DEST/"
ssh $SSH_OPTS "$HOST_URL" "$RELOAD_CMD"
