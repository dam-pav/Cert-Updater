#!/bin/sh
set -eu

CONFIG=/acme/config/domains.yml
ACME_HOME=/root/.acme.sh

die() {
  echo "ERROR: $1" >&2
  exit 1
}

require_value() {
  if [ -z "$1" ]; then
    die "$2"
  fi
}

if [ ! -r "$CONFIG" ]; then
  die "$CONFIG is not readable."
fi

domain_count=$(yq e '.domains // [] | length' "$CONFIG")

if [ "$domain_count" -eq 0 ]; then
  die "No domains configured in $CONFIG."
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

  host_url=$(yq e "$domain_path.host.host_url // \"\"" "$CONFIG")
  host_dest=$(yq e "$domain_path.host.dest // \"\"" "$CONFIG")
  host_reload=$(yq e "$domain_path.host.reload // \"\"" "$CONFIG")
  require_value "$host_url" "Domain $domain: host.host_url is required."
  require_value "$host_dest" "Domain $domain: host.dest is required."
  require_value "$host_reload" "Domain $domain: host.reload is required."

  cert_dir="${ACME_HOME}/${domain}_ecc"

  env_keys=$(yq e "$domain_path | (.dns // {}) | .env // {} | keys | .[]" "$CONFIG")
  if [ -n "$dns_provider" ]; then
    echo "  -> configuring DNS provider: $dns_provider"
  else
    echo "  -> no DNS provider configured, using default challenge"
  fi

  if [ -n "$env_keys" ]; then
    for key in $env_keys; do
      value=$(yq e "$domain_path | (.dns // {}) | .env.\"$key\" // \"\"" "$CONFIG")
      export "$key=$value"
    done
  fi

  if [ ! -d "$cert_dir" ]; then
    echo "  -> issuing certificate"

    if [ -n "$dns_provider" ]; then
      acme.sh --issue \
        --dns "dns_${dns_provider}" \
        -d "$domain" \
        --keylength "$keylength"
    else
      acme.sh --issue \
        -d "$domain" \
        --keylength "$keylength"
    fi
  else
    echo "  -> certificate already exists"
  fi

  echo "  -> installing deploy hook"

  acme.sh --install-cert -d "$domain" \
    --ecc \
    --key-file       "/acme/export/${domain}/key.pem" \
    --fullchain-file "/acme/export/${domain}/cert.pem" \
    --reloadcmd      "/acme/bin/deploy.sh \
                      $domain \
                      $host_url \
                      $host_dest \
                      \"$host_reload\""

  i=$((i + 1))
done
