#!/bin/sh
# Scheduling controls when this worker invokes acme.sh, not its eligibility rules.

load_renewal_margin() {
  renewal_margin_days=30
  if [ "$(yq e 'has("renewal_margin_days")' "$1")" = "true" ]; then
    renewal_margin_days=$(yq e '.renewal_margin_days' "$1")
    renewal_type=$(yq e '.renewal_margin_days | tag' "$1")
    if [ "$renewal_type" != "!!int" ] || ! [ "$renewal_margin_days" -ge 1 ] 2>/dev/null || ! [ "$renewal_margin_days" -le 365 ] 2>/dev/null; then
      echo "ERROR: renewal_margin_days must be an integer between 1 and 365." >&2
      return 1
    fi
  fi
}

# Return the next invocation time. Once inside the margin, keep checking at the
# fallback interval even when acme.sh skips renewal because it is not yet due.
next_check_time() {
  check_time=$(($1 - renewal_margin_days * 86400))
  if [ "$check_time" -le "$2" ]; then
    check_time=$(($2 + $3))
  fi
  printf '%s\n' "$check_time"
}

certificate_expiry() {
  cert_file=$1

  [ -r "$cert_file" ] || return 1

  # OpenSSL versions that support ISO output avoid an extra parsing step.
  expiry=$(openssl x509 -in "$cert_file" -noout -enddate -dateopt iso_8601 2>/dev/null |
    sed -n 's/^notAfter=//p')
  if [ -n "$expiry" ]; then
    printf '%s\n' "$expiry" | sed 's/ /T/'
    return 0
  fi

  # BusyBox date cannot parse OpenSSL's default "Jul 22 12:34:56 2026 GMT"
  # output, so normalize its fixed UTC representation without calling date.
  not_after=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | sed -n 's/^notAfter=//p')
  [ -n "$not_after" ] || return 1
  set -- $not_after
  [ "$#" -eq 5 ] && [ "$5" = "GMT" ] || return 1
  case "$1" in
    Jan) month=1 ;; Feb) month=2 ;; Mar) month=3 ;; Apr) month=4 ;;
    May) month=5 ;; Jun) month=6 ;; Jul) month=7 ;; Aug) month=8 ;;
    Sep) month=9 ;; Oct) month=10 ;; Nov) month=11 ;; Dec) month=12 ;;
    *) return 1 ;;
  esac
  day=${2#0}
  case "$day:$3:$4" in *[!0-9:]*|::*|*:) return 1 ;; esac
  printf '%s-%02d-%02dT%sZ\n' "$4" "$month" "$day" "$3"
}

