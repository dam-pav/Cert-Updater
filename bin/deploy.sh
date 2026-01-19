#!/bin/sh
set -e

DOMAIN="$1"
HOST_URL="$2"
DEST="$3"
RELOAD_CMD="$4"

SRC="/acme/export/${DOMAIN}"

echo "Deploying $DOMAIN to $HOST_URL:$DEST"

ssh "$HOST_URL" "mkdir -p '$DEST'"
rsync -az "$SRC/" "$HOST_URL:$DEST/"
ssh "$HOST_URL" "$RELOAD_CMD"
