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
host_count=$(yq e '.hosts // {} | keys | length' "$CONFIG" 2>/dev/null || echo "0")

json_string() {
  VALUE=$1 yq e -n -o=json -I=0 'strenv(VALUE)'
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

log_host_diagnostic() {
  previous_status=$(HOST_NAME=$1 yq e '.hosts[]? | select(.name == strenv(HOST_NAME)) | .operational' "$STATUS_FILE" 2>/dev/null | head -n 1)
  if [ "$previous_status" = "$2" ]; then
    return
  fi
  printf 'Host diagnostic %s: %s (%s)\n' "$1" "$2" "$3" >&2
}

diagnose_host() {
  host_name=$1
  host_url=$2
  dest=$3
  transfer=$4

  if [ -z "$host_url" ]; then
    log_host_diagnostic "$host_name" "Unreachable" "missing host URL"
    printf 'Unreachable'
    return
  fi

  mkdir -p "/cert-updater/home/.ssh-runtime/${host_name}"
  ssh_opts="-o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 -o UserKnownHostsFile=/cert-updater/home/.ssh-runtime/${host_name}/known_hosts"
  probe_output=$(ssh $ssh_opts "$host_url" "true" 2>&1)
  probe_code=$?

  if [ "$probe_code" -ne 0 ]; then
    case "$(printf '%s' "$probe_output" | tr '[:upper:]' '[:lower:]')" in
      *"permission denied"*|*"publickey"*)
        log_host_diagnostic "$host_name" "MissingKey" "${probe_output:-ssh exited $probe_code}"
        printf 'MissingKey'
        ;;
      *)
        log_host_diagnostic "$host_name" "Unreachable" "${probe_output:-ssh exited $probe_code}"
        printf 'Unreachable'
        ;;
    esac
    return
  fi

  if [ -z "$dest" ]; then
    log_host_diagnostic "$host_name" "NoDest" "no configured domain destination for host"
    printf 'NoDest'
    return
  fi

  quoted_dest=$(shell_quote "$dest")
  delivery_output=$(ssh $ssh_opts "$host_url" "mkdir -p $quoted_dest && tmp=$quoted_dest/.cert-updater-write-test.\$\$ && : > \"\$tmp\" && rm -f \"\$tmp\"" 2>&1)
  delivery_code=$?
  if [ "$delivery_code" -eq 0 ]; then
    log_host_diagnostic "$host_name" "Ready" "SSH and destination write test succeeded via $transfer"
    printf 'Ready'
  else
    log_host_diagnostic "$host_name" "Error" "${delivery_output:-destination write test exited $delivery_code}"
    printf 'Error'
  fi
}

# Start building JSON
hosts_json=""
domains_json=""

i=0
while [ "$i" -lt "$host_count" ]; do
  host_name=$(yq e ".hosts // {} | keys | .[$i]" "$CONFIG")
  host_url=$(HOST_NAME=$host_name yq e '.hosts[strenv(HOST_NAME)].url // ""' "$CONFIG")
  host_transfer=$(HOST_NAME=$host_name yq e '.hosts[strenv(HOST_NAME)].transfer // "scp"' "$CONFIG")
  host_reload=$(HOST_NAME=$host_name yq e '.hosts[strenv(HOST_NAME)].reload // ""' "$CONFIG")
  host_domain_count=$(HOST_NAME=$host_name yq e '[.domains[]? | select(.host == strenv(HOST_NAME))] | length' "$CONFIG")
  host_dest=$(HOST_NAME=$host_name yq e '[.domains[]? | select(.host == strenv(HOST_NAME)) | .dest // ""] | .[0] // ""' "$CONFIG")
  host_operational=$(diagnose_host "$host_name" "$host_url" "$host_dest" "$host_transfer")

  host_entry=$(cat <<ENTRY
    {
      "name": $(json_string "$host_name"),
      "url": $(json_string "$host_url"),
      "operational": $(json_string "$host_operational"),
      "transfer": $(json_string "$host_transfer"),
      "reload": $(json_string "$host_reload"),
      "domain_count": $host_domain_count
    }
ENTRY
)

  if [ -n "$hosts_json" ]; then
    hosts_json="${hosts_json},
${host_entry}"
  else
    hosts_json="${host_entry}"
  fi

  i=$((i + 1))
done

if [ "$domain_count" -eq 0 ] 2>/dev/null || [ -z "$domain_count" ]; then
  echo "No domains configured."
else
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
    expires_on=""
    next_renewal=""
    renewal_epoch=""

    cert_file="/cert-updater/export/${domain}/cert.pem"
    if [ -r "$cert_file" ]; then
      not_after=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')
      if [ -n "$not_after" ]; then
        expires_on=$(date -u -d "$not_after" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
      fi
    fi
  
    if [ -r "$cert_conf" ]; then
      # Extract Le_NextRenewTime
      next_renewal=$(sed -n "s/^Le_NextRenewTime=['\"]\{0,1\}\([0-9][0-9]*\)['\"]\{0,1\}$/\1/p" "$cert_conf" | head -n 1)
    
      if [ -n "$next_renewal" ] && [ "$next_renewal" -gt 0 ] 2>/dev/null; then
        # Next renewal is in the future
        next_update=$(date -u -d "@$next_renewal" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -r "$next_renewal" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
        renewal_epoch=$next_renewal
      
        # acme.sh records the successful issue/renewal time as Le_CertCreateTime.
        # Keep Le_IssueTime as a fallback for older or externally generated state.
        issue_time=$(sed -n "s/^Le_CertCreateTime=['\"]\{0,1\}\([0-9][0-9]*\)['\"]\{0,1\}$/\1/p" "$cert_conf" | head -n 1)
        if [ -z "$issue_time" ]; then
          issue_time=$(sed -n "s/^Le_IssueTime=['\"]\{0,1\}\([0-9][0-9]*\)['\"]\{0,1\}$/\1/p" "$cert_conf" | head -n 1)
        fi
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
      "name": $(json_string "$domain"),
      "host": $(json_string "$host_name"),
      "provider": $(json_string "$dns_provider"),
      "last_checked": $(json_string "$NOW"),
      "last_updated": $(json_string "$last_updated"),
      "expires_on": $(json_string "$expires_on"),
      "next_update": $(json_string "$next_update"),
      "status": $(json_string "$status")
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
fi

# Write final status.json
cat > "$STATUS_FILE" <<EOF
{
  "last_sync": "$NOW",
  "hosts": [
${hosts_json}
  ],
  "domains": [
${domains_json}
  ]
}
EOF

echo "Status updated: $STATUS_FILE"
