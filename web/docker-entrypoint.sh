#!/bin/sh
set -eu

SETTINGS_PATH=${SETTINGS_PATH:-/cert-updater/config/settings.yml}
NGINX_CONFIG_PATH=${NGINX_CONFIG_PATH:-/etc/nginx/conf.d/default.conf}

normalize_subpath() {
  value=$1
  while [ "${value#/}" != "$value" ]; do
    value=${value#/}
  done
  while [ "${value%/}" != "$value" ]; do
    value=${value%/}
  done
  printf '%s' "$value"
}

read_subpath() {
  if [ ! -f "$SETTINGS_PATH" ]; then
    printf ''
    return
  fi

  if command -v yq >/dev/null 2>&1; then
    yq e '.webui.subpath // ""' "$SETTINGS_PATH"
    return
  fi

  awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    /^[^[:space:]][^:]*:/ {
      in_webui = ($0 ~ /^webui:[[:space:]]*$/)
      next
    }
    in_webui && /^[[:space:]]+subpath:[[:space:]]*/ {
      value = $0
      sub(/^[[:space:]]*subpath:[[:space:]]*/, "", value)
      sub(/[[:space:]]+#.*$/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if ((value ~ /^".*"$/) || (value ~ /^\047.*\047$/)) {
        value = substr(value, 2, length(value) - 2)
      }
      print value
      exit
    }
  ' "$SETTINGS_PATH"
}

write_api_locations() {
  prefix=$1

  cat <<EOF
    location = ${prefix}/status.json {
        proxy_pass http://cert-updater:8081;
        proxy_set_header Authorization \$http_authorization;
    }

    location = ${prefix}/api/status {
        proxy_pass http://cert-updater:8081;
        proxy_set_header Authorization \$http_authorization;
    }

    location = ${prefix}/api/auth/me {
        proxy_pass http://cert-updater:8081;
        proxy_set_header Authorization \$http_authorization;
    }

    location = ${prefix}/api/users {
        proxy_pass http://cert-updater:8081;
        proxy_set_header Authorization \$http_authorization;
    }

    location = ${prefix}/api/hosts {
        proxy_pass http://cert-updater:8081;
        proxy_set_header Authorization \$http_authorization;
    }

    location = ${prefix}/api/config {
        proxy_pass http://cert-updater:8081;
        proxy_set_header Authorization \$http_authorization;
    }

    location = ${prefix}/api/users/write {
        limit_except POST { deny all; }
        proxy_pass http://cert-updater:8081;
        proxy_set_header Authorization \$http_authorization;
        proxy_set_header Content-Type \$content_type;
    }

    location = ${prefix}/api/ssh/public-key {
        proxy_pass http://cert-updater:8081;
        proxy_set_header Authorization \$http_authorization;
    }

    location = ${prefix}/api/sync/run {
        limit_except POST { deny all; }
        proxy_pass http://cert-updater:8081;
        proxy_set_header Authorization \$http_authorization;
        proxy_set_header Content-Type \$content_type;
    }

    location = ${prefix}/api/settings/read {
        proxy_pass http://cert-updater:8081;
        proxy_set_header Authorization \$http_authorization;
    }

    location = ${prefix}/api/settings/write {
        limit_except POST { deny all; }
        proxy_pass http://cert-updater:8081;
        proxy_set_header Authorization \$http_authorization;
        proxy_set_header Content-Type \$content_type;
    }
EOF
}

raw_subpath=$(read_subpath)
subpath=$(normalize_subpath "$raw_subpath")
regex_subpath=$(printf '%s' "$subpath" | sed 's/[.[\*^$()+?{}|]/\\&/g')

case "$subpath" in
  *[!A-Za-z0-9._~/-]*|*//*)
    echo "Invalid webui.subpath '$raw_subpath'. Use path tokens like 'certs' or 'apps/certs'." >&2
    exit 1
    ;;
esac

{
  cat <<'EOF'
server {
    listen 80;
    server_name _;

    root /usr/share/nginx/html;
    index index.html;

EOF

  if [ -n "$subpath" ]; then
    cat <<EOF
    location = / {
        return 302 /${subpath}/;
    }

    location = /${subpath} {
        return 301 /${subpath}/;
    }

    location = /${subpath}/ {
        try_files /index.html =404;
    }

EOF
    write_api_locations "/${subpath}"
    cat <<EOF

    location /${subpath}/ {
        rewrite ^/${regex_subpath}/(.*)\$ /\$1 break;
        try_files \$uri \$uri/ =404;
    }

EOF
  else
    cat <<'EOF'
    location = / {
        try_files /index.html =404;
    }

EOF
    write_api_locations ""
    cat <<'EOF'

    location / {
        try_files $uri $uri/ =404;
    }

EOF
  fi

  cat <<'EOF'
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options DENY;
}
EOF
} > "$NGINX_CONFIG_PATH"

exec nginx -g 'daemon off;'
