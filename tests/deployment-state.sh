#!/bin/sh
# Run in an isolated worker container with this checkout mounted at /work:
# docker run --rm --network none --entrypoint sh -v "$PWD:/work:ro" \
#   --tmpfs /cert-updater/state --tmpfs /cert-updater/config \
#   --tmpfs /cert-updater/export --tmpfs /cert-updater/home \
#   ghcr.io/dam-pav/cert-updater:latest /work/tests/deployment-state.sh
set -eu

cp /work/bin/*.sh /cert-updater/bin/
chmod +x /cert-updater/bin/*.sh
. /cert-updater/bin/renewal-schedule.sh
. /cert-updater/bin/deployment-state.sh
mkdir -p /tmp/mock /cert-updater/state/example.com_ecc /cert-updater/export/example.com
remote_dir="/tmp/remote cert's"
mkdir -p "$remote_dir"
export PATH="/tmp/mock:$PATH"
cat > /tmp/mock/ssh <<'MOCK'
#!/bin/sh
if [ "${MOCK_SSH_FAIL:-0}" = 1 ]; then
  echo 'Permission denied (publickey,password).' >&2
  exit 255
fi
for argument do command=$argument; done
if [ "$command" = reload ]; then
  exit "${MOCK_RELOAD_FAIL:-0}"
fi
sh -c "$command"
MOCK
cat > /tmp/mock/scp <<'MOCK'
#!/bin/sh
if [ "${MOCK_STALE_COPY:-0}" = 1 ]; then exit 0; fi
for argument do
  case "$argument" in
    */key.pem) key=$argument ;;
    */cert.pem) cert=$argument ;;
    user@mock:*) destination=${argument#user@mock:} ;;
  esac
done
cp "$key" "$cert" "$destination"
MOCK
cat > /tmp/mock/acme.sh <<'MOCK'
#!/bin/sh
case "$1" in
  --renew) exit 2 ;;
  --install-cert)
    cp /cert-updater/state/example.com_ecc/fullchain.cer /cert-updater/export/example.com/cert.pem
    /cert-updater/bin/deploy.sh example.com router user@mock "$REMOTE_DIR" reload scp
    ;;
esac
MOCK
chmod +x /tmp/mock/*
export REMOTE_DIR=$remote_dir
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 90 \
  -subj /CN=example.com -keyout /cert-updater/export/example.com/key.pem \
  -out /cert-updater/state/example.com_ecc/fullchain.cer >/dev/null 2>&1
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 10 \
  -subj /CN=example.com -keyout /tmp/old.key -out "$remote_dir/cert.pem" >/dev/null 2>&1
cp /cert-updater/state/example.com_ecc/fullchain.cer /cert-updater/export/example.com/cert.pem
desired=$(managed_certificate example.com)
receipt=/cert-updater/state/.example.com.deployment.json
pending=/cert-updater/state/.example.com.deploy-pending

check() {
  observed=$(inspect_deployment example.com router user@mock "$remote_dir" reload "$desired")
  printf '%s' "$observed" | EXPECTED=$1 yq -e '.deployment_status == strenv(EXPECTED)' - >/dev/null
  echo "PASS: remote deployment is $1"
}

check outdated
test ! -f "$receipt"
MOCK_STALE_COPY=1 /cert-updater/bin/deploy.sh example.com router user@mock "$remote_dir" reload scp && exit 1
test -f "$pending"
test ! -f "$receipt"
MOCK_RELOAD_FAIL=1 /cert-updater/bin/deploy.sh example.com router user@mock "$remote_dir" reload scp && exit 1
test -f "$pending"
test ! -f "$receipt"
check pending
/cert-updater/bin/deploy.sh example.com router user@mock "$remote_dir" reload scp
test ! -f "$pending"
test -f "$receipt"
check current
saved_receipt=$(cat "$receipt")
MOCK_RELOAD_FAIL=1 /cert-updater/bin/deploy.sh example.com router user@mock "$remote_dir" reload scp && exit 1
test "$(cat "$receipt")" = "$saved_receipt"
check pending
/cert-updater/bin/deploy.sh example.com router user@mock "$remote_dir" reload scp
check current
saved_receipt=$(cat "$receipt")
# A changed chain must be detected even when the leaf fingerprint matches.
cp "$desired" /tmp/original-bundle.pem
cat "$desired" >> "$remote_dir/cert.pem"
check outdated
cp "$remote_dir/cert.pem" "$desired"
check unverified
cp /tmp/original-bundle.pem "$desired"
cp "$desired" "$remote_dir/cert.pem"
# Starting a fresh process preserves the deployment receipt and remote check.
sh -c '. /cert-updater/bin/renewal-schedule.sh; . /cert-updater/bin/deployment-state.sh; inspect_deployment example.com router user@mock "$REMOTE_DIR" reload /cert-updater/state/example.com_ecc/fullchain.cer' |
  yq -e '.deployment_status == "current" and .last_deployed != ""' - >/dev/null
echo 'PASS: deployment confirmation survives a process restart'
observed=$(inspect_deployment example.com router user@mock "$remote_dir" changed-reload "$desired")
printf '%s' "$observed" | yq -e '.deployment_status == "unverified" and .last_deployed == ""' - >/dev/null
echo 'PASS: receipt does not apply to a changed target configuration'
MOCK_SSH_FAIL=1 check error
test "$(cat "$receipt")" = "$saved_receipt"
rm "$remote_dir/cert.pem"
check missing
printf 'not a certificate\n' > "$remote_dir/cert.pem"
check error

cat > /cert-updater/config/settings.yml <<CONFIG
hosts:
  router:
    url: user@mock
    reload: reload
domains:
  - name: example.com
    host: router
    keylength: ec-256
    dest: "$remote_dir"
    dns:
      provider: cf
CONFIG
touch /cert-updater/state/example.com_ecc/example.com.conf
# A newer local certificate must not hide an expired remote certificate.
openssl x509 -in "$desired" -signkey /cert-updater/export/example.com/key.pem -days -1 \
  -out "$remote_dir/cert.pem" >/dev/null 2>&1
/cert-updater/bin/update-status.sh
yq -e '.domains[0].status == "expired" and .domains[0].local_status == "valid" and .domains[0].deployment.deployment_status == "outdated" and .domains[0].deploy_pending == true' /cert-updater/export/status.json >/dev/null
echo 'PASS: dashboard reports expired remote certificate despite valid local certificate'
# Pending recovery uses the fallback interval, not the newer local expiry.
sed -n '1,/^SYNC_INTERVAL_SECONDS=/p' /work/entrypoint.sh | sed '$d' > /tmp/schedule-functions.sh
sh -c '. /tmp/schedule-functions.sh; refresh_sync_interval 86400; test "$SYNC_INTERVAL_SECONDS" -le 86400'
echo 'PASS: pending deployment recovery is scheduled within the fallback interval'
# Older failures with no pending marker must also be repaired automatically.
rm "$pending"
/cert-updater/bin/sync-certs.sh
yq -e '.domains[0].status == "valid" and .domains[0].deployment.deployment_status == "current" and .domains[0].deploy_pending == false' /cert-updater/export/status.json >/dev/null
echo 'PASS: skipped renewal repairs the outdated remote certificate'
# Losing the receipt is conservative: a matching file does not prove a reload.
rm "$receipt"
check unverified
