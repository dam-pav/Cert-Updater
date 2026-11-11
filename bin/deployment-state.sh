#!/bin/sh
# Remote certificate verification and persistent deployment receipts.

deployment_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

managed_certificate() (
  for managed_file in \
    "/cert-updater/state/${1}_ecc/fullchain.cer" \
    "/cert-updater/state/${1}/fullchain.cer" \
    "/cert-updater/export/${1}/cert.pem"; do
    if [ -r "$managed_file" ]; then
      printf '%s\n' "$managed_file"
      return 0
    fi
  done
  return 1
)

certificate_fingerprint() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | sed -n 's/.*=//p'
}

certificate_bundle_digest() {
  openssl dgst -sha256 "$1" 2>/dev/null | sed -n 's/.*= *//p'
}

read_remote_certificate() (
  mkdir -p "/cert-updater/home/.ssh-runtime/$1"
  remote_path=$(deployment_quote "$3/cert.pem")
  ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 \
    -o "UserKnownHostsFile=/cert-updater/home/.ssh-runtime/$1/known_hosts" \
    "$2" "if [ -f $remote_path ]; then cat $remote_path; else exit 44; fi" > "$4"
)

deployment_receipt() (
  DOMAIN=$1 HOST_URL=$2 DEST=$3 RELOAD_CMD=$4 yq e -o=json -I=0 \
    'select(.host_url == strenv(HOST_URL) and .dest == strenv(DEST) and .reload == strenv(RELOAD_CMD))' \
    "/cert-updater/state/.${1}.deployment.json" 2>/dev/null
)

record_deployment() (
  receipt_tmp=$(mktemp "/cert-updater/state/.${1}.deployment.XXXXXX")
  trap 'rm -f "$receipt_tmp"' EXIT HUP INT TERM
  DOMAIN=$1 HOST_URL=$2 DEST=$3 RELOAD_CMD=$4 FINGERPRINT=$5 BUNDLE_DIGEST=$(certificate_bundle_digest "$6") \
    DEPLOYED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ") \
    yq e -n -o=json '{"domain": strenv(DOMAIN), "host_url": strenv(HOST_URL), "dest": strenv(DEST), "reload": strenv(RELOAD_CMD), "fingerprint": strenv(FINGERPRINT), "bundle_digest": strenv(BUNDLE_DIGEST), "deployed_at": strenv(DEPLOYED_AT)}' > "$receipt_tmp" || return 1
  mv "$receipt_tmp" "/cert-updater/state/.${1}.deployment.json"
)

inspect_deployment() (
  # domain, host name, SSH URL, destination, reload command, desired certificate
  remote_tmp=$(mktemp)
  trap 'rm -f "$remote_tmp"' EXIT HUP INT TERM
  desired_fingerprint=$(certificate_fingerprint "$6")
  receipt=$(deployment_receipt "$1" "$3" "$4" "$5" || true)
  last_deployed=$(printf '%s' "$receipt" | yq e '.deployed_at // ""' - 2>/dev/null)
  deployed_fingerprint=$(printf '%s' "$receipt" | yq e '.fingerprint // ""' - 2>/dev/null)
  deployed_digest=$(printf '%s' "$receipt" | yq e '.bundle_digest // ""' - 2>/dev/null)
  deployment_status=unverified
  remote_status=unknown
  remote_expiry=
  remote_fingerprint=
  remote_result=0
  read_remote_certificate "$2" "$3" "$4" "$remote_tmp" || remote_result=$?
  if [ "$remote_result" -eq 44 ]; then
    deployment_status=missing
  elif [ "$remote_result" -ne 0 ]; then
    deployment_status=error
  else
    remote_fingerprint=$(certificate_fingerprint "$remote_tmp")
    remote_expiry=$(certificate_expiry "$remote_tmp" || true)
    remote_epoch=$(date -u -d "$(printf '%s' "$remote_expiry" | sed 's/T/ /; s/Z$//')" +%s 2>/dev/null || true)
    if [ -n "$remote_expiry" ] && [ -n "$remote_epoch" ]; then
      if [ "$remote_epoch" -le "$(date -u +%s)" ]; then
        remote_status=expired
      else
        remote_status=valid
      fi
    fi
    if [ -z "$remote_fingerprint" ]; then
      deployment_status=error
    elif [ -n "$desired_fingerprint" ]; then
      if [ "$remote_fingerprint" != "$desired_fingerprint" ] || ! cmp -s "$6" "$remote_tmp"; then
        deployment_status=outdated
      elif [ -f "/cert-updater/state/.${1}.deploy-pending" ]; then
        deployment_status=pending
      elif [ "$deployed_fingerprint" = "$desired_fingerprint" ] && \
           [ "$deployed_digest" = "$(certificate_bundle_digest "$6")" ]; then
        deployment_status=current
      fi
    fi
  fi
  DEPLOYMENT_STATUS=$deployment_status REMOTE_STATUS=$remote_status REMOTE_EXPIRY=$remote_expiry \
    REMOTE_FINGERPRINT=$remote_fingerprint LOCAL_FINGERPRINT=$desired_fingerprint LAST_DEPLOYED=$last_deployed \
    CHECKED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ") \
    yq e -n -o=json -I=0 '{"deployment_status": strenv(DEPLOYMENT_STATUS), "remote_status": strenv(REMOTE_STATUS), "remote_expires_on": strenv(REMOTE_EXPIRY), "remote_fingerprint": strenv(REMOTE_FINGERPRINT), "local_fingerprint": strenv(LOCAL_FINGERPRINT), "last_deployed": strenv(LAST_DEPLOYED), "deployment_checked_at": strenv(CHECKED_AT)}'
)
