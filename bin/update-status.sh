#!/bin/sh

CONFIG=/cert-updater/config/settings.yml
STATUS_FILE=/cert-updater/export/status.json
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Get current timestamp in seconds for calculations
NOW_EPOCH=$(date -u +%s)

die() {
  echo "ERROR: $1" >&2
}

# Check if config exists and is readable
if [ ! -r "$CONFIG" ]; then
  die "$CONFIG is not readable."
  exit 1
fi

domain_count=$(yq e '.domains // [] | length' "$CONFIG" 2>/dev/null || echo "0")

if [ "$domain_count" -eq 0 ] 2>/dev/null || [ -z "$domain_count" ]; then
  echo "No domains configured."
  cat > "$STATUS_FILE" <<EOF
{
  "last_sync": "$NOW",
  "domains": []
}
EOF
  exit 0
fi

# Start building JSON
domains_json=""

i=0
while [ "$i" -lt "$domain_count" ]; do
  domain_path=.domains[$i]
  domain=$(yq e "$domain_path.name // \"\"" "$CONFIG")
  host_name=$(yq e "$domain_path.host // \"\"" "$CONFIG")
  dns_provider=$(yq e "$domain_path.dns.provider // \"\"" "$CONFIG")

  # Get renewal time from acme.sh config
  cert_conf="/cert-updater/state/${domain}_ecc/${domain}.conf"
  
  last_updated=""
  next_update=""
  renewal_epoch=""
  
  if [ -r "$cert_conf" ]; then
    # Extract Le_NextRenewTime
    next_renewal=$(sed -n "s/^Le_NextRenewTime=['\"]\{0,1\}\([0-9][0-9]*\)['\"]\{0,1\}$/\1/p" "$cert_conf" | head -n 1)
    
    if [ -n "$next_renewal" ] && [ "$next_renewal" -gt 0 ] 2>/dev/null; then
      # Next renewal is in the future
      next_update=$(date -u -d "@$next_renewal" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -r "$next_renewal" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
      renewal_epoch=$next_renewal
      
      # Get issue time for last_updated
      issue_time=$(sed -n "s/^Le_IssueTime=['\"]\{0,1\}\([0-9][0-9]*\)['\"]\{0,1\}$/\1/p" "$cert_conf" | head -n 1)
      if [ -n "$issue_time" ] && [ "$issue_time" -gt 0 ] 2>/dev/null; then
        last_updated=$(date -u -d "@$issue_time" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -r "$issue_time" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
      fi
    fi
  fi
  
  # Determine status
  if [ -z "$next_renewal" ] || [ "$next_renewal" -eq 0 ] 2>/dev/null; then
    status="unknown"
  elif [ "$renewal_epoch" -le "$NOW_EPOCH" ] 2>/dev/null; then
    status="expired"
  else
    status="valid"
  fi
  
  # Build domain JSON entry
  domain_entry=$(cat <<ENTRY
    {
      "name": "$domain",
      "host": "$host_name",
      "provider": "$dns_provider",
      "last_checked": "$NOW",
      "last_updated": "$last_updated",
      "next_update": "$next_update",
      "status": "$status"
    }
ENTRY
)
  
  if [ -n "$domains_json" ]; then
    domains_json="${domains_json},
${domain_entry}"
  else
    domains_json="${domain_entry}"
  fi
  
  i=$((i + 1))
done

# Write final status.json
cat > "$STATUS_FILE" <<EOF
{
  "last_sync": "$NOW",
  "domains": [
${domains_json}
  ]
}
EOF

echo "Status updated: $STATUS_FILE"