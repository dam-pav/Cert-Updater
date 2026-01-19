#!/bin/sh
set -e

CONFIG=/acme/config/domains.yml
ACME_HOME=/root/.acme.sh

domains=$(yq e '.domains[].name' "$CONFIG")

for domain in $domains; do
  echo "==> Processing $domain"

  keylength=$(yq e ".domains[] | select(.name == \"$domain\") | .keylength" "$CONFIG")
  dns_provider=$(yq e ".domains[] | select(.name == \"$domain\") | .dns.provider" "$CONFIG")

  host_url=$(yq e ".domains[] | select(.name == \"$domain\") | .host.host_url" "$CONFIG")
  host_dest=$(yq e ".domains[] | select(.name == \"$domain\") | .host.dest" "$CONFIG")
  host_reload=$(yq e ".domains[] | select(.name == \"$domain\") | .host.reload" "$CONFIG")

  cert_dir="${ACME_HOME}/${domain}_ecc"

  echo "  -> configuring DNS provider: $dns_provider"

  # Export provider-specific env vars
  env_keys=$(yq e ".domains[] | select(.name == \"$domain\") | .dns.env | keys | .[]" "$CONFIG")
  for key in $env_keys; do
    value=$(yq e ".domains[] | select(.name == \"$domain\") | .dns.env.${key}" "$CONFIG")
    export "$key=$value"
  done

  if [ ! -d "$cert_dir" ]; then
    echo "  -> issuing certificate"

    acme.sh --issue \
      --dns "dns_${dns_provider}" \
      -d "$domain" \
      --keylength "$keylength"
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
done
