#!/bin/sh
set -eu

CONFIG=/acme/config/domains.yml
ACME_HOME=/acme/state

die() {
  echo "ERROR: $1" >&2
  exit 1
}

require_value() {
  if [ -z "$1" ]; then
    die "$2"
  fi
}

check_writable_path() {
  path=$1
  label=$2
  if [ -e "$path" ]; then
    if [ ! -w "$path" ]; then
      die "$label ($path) is not writable"
    fi
    echo "  -> $label is writable: $path"
  else
    parent=$(dirname "$path")
    if [ -d "$parent" ] && [ -w "$parent" ]; then
      echo "  -> $label can be created under $parent"
    else
      die "$label ($path) is not writable; parent $parent is not writable"
    fi
  fi
}

if [ ! -r "$CONFIG" ]; then
  die "$CONFIG is not readable."
fi

domain_count=$(yq e '.domains // [] | length' "$CONFIG")

if [ "$domain_count" -eq 0 ]; then
  die "No domains configured in $CONFIG."
fi

# Validate hosts section exists
hosts_count=$(yq e '.hosts // {} | keys | length' "$CONFIG")
if [ "$hosts_count" -eq 0 ]; then
  die "No hosts defined in $CONFIG. Add a 'hosts' section."
fi

# Register ACME account if email is provided and not already registered
# This is optional for Let's Encrypt but recommended for expiry notifications
if [ -n "${ACME_ACCOUNT_EMAIL:-}" ]; then
  if ! acme.sh --show-account >/dev/null 2>&1; then
    echo "Registering ACME account for $ACME_ACCOUNT_EMAIL"
    acme.sh --register-account -m "$ACME_ACCOUNT_EMAIL"
  fi
fi

i=0
while [ "$i" -lt "$domain_count" ]; do
  domain_path=.domains[$i]
  domain=$(yq e "$domain_path.name // \"\"" "$CONFIG")
  require_value "$domain" "Domain entry #$((i + 1)) is missing a name."
  echo "==> Processing $domain"

  keylength=$(yq e "$domain_path.keylength // \"\"" "$CONFIG")
  require_value "$keylength" "Domain $domain: keylength is required."

  dns_provider=$(yq e "$domain_path.dns.provider // \"\"" "$CONFIG")
  dns_present=$(yq e "$domain_path | has(.dns)" "$CONFIG")
  if [ "$dns_present" = "true" ]; then
    require_value "$dns_provider" "Domain $domain: dns.provider is required when .dns is present."
  fi

  # Get host reference and look up host details
  host_name=$(yq e "$domain_path.host // \"\"" "$CONFIG")
  require_value "$host_name" "Domain $domain: host is required (reference to hosts section)."
  
  # Look up host in hosts section
  host_url=$(yq e ".hosts.${host_name}.url // \"\"" "$CONFIG")
  host_transfer=$(yq e ".hosts.${host_name}.transfer // \"scp\"" "$CONFIG")
  host_reload=$(yq e ".hosts.${host_name}.reload // \"\"" "$CONFIG")
  
  require_value "$host_url" "Domain $domain: host '$host_name' not found in hosts section or missing 'url'."
  require_value "$host_reload" "Host $host_name: reload command is required."
  
  # dest is per-domain
  host_dest=$(yq e "$domain_path.dest // \"\"" "$CONFIG")
  require_value "$host_dest" "Domain $domain: dest is required."

  cert_dir="${ACME_HOME}/${domain}_ecc"
  export_dir="/acme/export/${domain}"

  env_keys=$(yq e "$domain_path | (.dns // {}) | .env // {} | keys | .[]" "$CONFIG")
  if [ -n "$dns_provider" ]; then
    echo "  -> configuring DNS provider: $dns_provider"
  else
    echo "  -> no DNS provider configured, using default challenge"
  fi

  if [ -n "$env_keys" ]; then
    for key in $env_keys; do
      raw_value=$(yq e "$domain_path | (.dns // {}) | .env.\"$key\" // \"\"" "$CONFIG")
      # Expand environment variable references like ${VAR_NAME}
      value=$(eval echo "$raw_value")
      echo "  -> setting $key"
      export "$key=$value"
    done
  fi

  check_writable_path "$cert_dir" "certificate directory"
  check_writable_path "$export_dir" "export directory"

  echo "  -> issuing/renewing certificate"

  if [ -n "$dns_provider" ]; then
    issue_result=0
    acme.sh --issue \
      --server letsencrypt \
      --dns "dns_${dns_provider}" \
      -d "$domain" \
      --keylength "$keylength" || issue_result=$?
    # acme.sh returns 0=success, 2=skip (not due), other=error
    if [ "$issue_result" -ne 0 ] && [ "$issue_result" -ne 2 ]; then
      echo "  -> WARNING: certificate issuance failed for $domain (exit $issue_result), will retry on next run"
      i=$((i + 1))
      continue
    fi
  else
    echo "  -> ERROR: Domain $domain: No DNS provider configured. Skipping."
    i=$((i + 1))
    continue
  fi

  echo "  -> installing deploy hook"

  mkdir -p "/acme/export/${domain}"

  if ! acme.sh --install-cert -d "$domain" \
    --ecc \
    --key-file       "/acme/export/${domain}/key.pem" \
    --fullchain-file "/acme/export/${domain}/cert.pem" \
    --reloadcmd      "/acme/bin/deploy.sh \
                      $domain \
                      $host_name \
                      $host_url \
                      $host_dest \
                      \"$host_reload\" \
                      $host_transfer"; then
    echo "  -> WARNING: deploy failed for $domain, will retry on next run"
  fi

  i=$((i + 1))
done
