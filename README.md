# Certificate Updater

Certificate Updater is a containerized automatic SSL/TLS certificate manager using [acme.sh](https://github.com/acmesh-official/acme.sh) with Let's Encrypt. Automatically issues, renews, and deploys certificates to remote hosts via SSH.

## Features

- **Automatic certificate issuance and renewal** via Let's Encrypt
- **DNS-01 challenge support** for wildcard certificates and internal servers
- **Remote deployment** via SSH (scp or rsync)
- **Multiple domains on multiple hosts** configured via a single YAML file
- **Non-root container** execution with configurable UID/GID
- **In-container sync loop** for automatic renewals with direct container logs
- **Web dashboard** for real-time certificate status monitoring
- **Lightweight role-based web access** with viewer and admin users

## Quick Start

1. Create a `.env` file with your configuration:

   ```env
   DATA_DIR=/path/to/data
   CERT_UID=1000
   CERT_GID=1000
   TZ=UTC
   ```
2. Start the init container (creates directories and SSH keys):

   ```bash
   docker compose up -d cert-updater-init
   ```
3. Copy `config/settings.yml.example` to your data directory and edit:

   ```bash
   mkdir -p ${DATA_DIR}/cert-updater/config
   cp config/settings.yml.example ${DATA_DIR}/cert-updater/config/settings.yml
   nano ${DATA_DIR}/cert-updater/config/settings.yml
   ```
4. Add the generated SSH public key to your target hosts (see "Target Host SSH Setup" below). The worker runs an initial sync when it starts, so install the key before starting the full stack if you want the first deployment to succeed.
5. Start the stack:

   ```bash
   docker compose up -d
   ```

   This pulls `ghcr.io/dam-pav/cert-updater:latest` and `ghcr.io/dam-pav/cert-updater-web:latest`.
6. Sign in to the dashboard with the default admin credentials and replace them:

   - Username: `admin`
   - Password: `admin`

## Web Dashboard

A built-in authenticated dashboard provides certificate and deployment target visibility. Access it at:

```
http://localhost:8080
```

The dashboard includes:

- **Domains view**: Domain name, target host, DNS provider, certificate status, last checked time, last update time, and next update time
- **Hosts view**: Host name, SSH URL, diagnostic status, transfer method, assigned domain count, and reload command
- **Host diagnostics**: Shows `Ready` when SSH works and the configured destination accepts a write test, `MissingKey` when SSH authentication fails because the public key is not installed, `Unreachable` when the host cannot be contacted, and red fallback statuses such as `NoDest` or `Error` for other deployment-readiness problems
- **Settings editor**: Admin users can edit `settings.yml` in the browser with validation before saving
- **SSH Key helper**: Shows the generated public key and copyable setup commands for configured target hosts
- **User management**: Admin users can manage all dashboard users; viewer users can change only their own password
- **Manual sync**: Admin users can request an immediate backend sync from the dashboard
- **Auto-refresh**: Certificate and host data refresh every 60 seconds
- **Manual refresh**: Click the floating refresh button
- **Role-based access**: `viewer` users can view certificate status, host summaries, the SSH key helper, and their own user row; `admin` users can also edit `settings.yml`, manage all users, and request manual syncs

Customize the port with the `WEB_PORT` environment variable:

```
WEB_PORT=80
```

> Warning: this WebUI does not provide its own SSL infrastructure. Do not expose this WebUI to untrusted networks. Put it behind a reverse proxy.

### Dashboard Users

Dashboard credentials are stored in `${DATA_DIR}/cert-updater/config/users.json`. If this file does not exist, the service creates a default admin user with username `admin` and password `admin`.

Replace the default password before exposing the dashboard beyond a trusted local network. Sign in as an admin, open **Users**, and enter the new password twice before saving. Admin users can add users, remove users, change roles, and reset passwords. Viewer users can open **Users** only for their own row and can change only their own password.

Passwords are stored as PBKDF2-SHA256 hashes. If you need to edit `${DATA_DIR}/cert-updater/config/users.json` manually, generate a hash first:

```bash
docker exec -it cert-updater /cert-updater/bin/hash-password.py
```

Then edit `${DATA_DIR}/cert-updater/config/users.json`:

```json
{
  "users": [
    {
      "username": "admin",
      "password_hash": "pbkdf2_sha256$260000$...",
      "role": "admin"
    },
    {
      "username": "viewer",
      "password_hash": "pbkdf2_sha256$260000$...",
      "role": "viewer"
    }
  ]
}
```

Supported roles are:

- `viewer`: can authenticate, view certificate status and host summaries, open the SSH key helper, and change their own password
- `admin`: can do everything a viewer can, plus read/write `settings.yml`, manage all users, and request manual syncs from the dashboard

## Portainer

1. Create a new "Repository" stack with
   - Repository URL: https://github.com/dam-pav/cert-updater.git
   - Compose path: docker-compose.yml
2. Add environment variables (at minimum: `DATA_DIR`, `CERT_UID`, `CERT_GID`)
3. After deployment, create `settings.yml` at `${DATA_DIR}/cert-updater/config/settings.yml`
4. Add the generated SSH public key to your target hosts (see "Target Host SSH Setup" below)
5. Restart the `cert-updater` service after adding the config:
   ```bash
   docker compose restart cert-updater
   ```

If you later find you need to make your own modifications to the compose file, you can simply Detach from Git anytime.

## Environment Variables

### Required

| Variable     | Description                                                    |
| ------------ | -------------------------------------------------------------- |
| `DATA_DIR` | Base directory for persistent data (e.g.,`/opt/docker-data`) |
| `CERT_UID` | User ID for the updater container (e.g.,`1000`)              |
| `CERT_GID` | Group ID for the updater container (e.g.,`1000`)             |

### Required for Cloudflare provider

| Variable          | Description           |
| ----------------- | --------------------- |
| `CF_API_TOKEN`  | Cloudflare API token  |
| `CF_ACCOUNT_ID` | Cloudflare Account ID |

### Required for DuckDNS provider

| Variable          | Description                      |
| ----------------- | -------------------------------- |
| `DUCKDNS_TOKEN` | DuckDNS token (if using DuckDNS) |

### Optional

| Variable                  | Description                                                                                        |
| ------------------------- | -------------------------------------------------------------------------------------------------- |
| `ACME_ACCOUNT_EMAIL`    | Email for Let's Encrypt notifications (expiry warnings)                                            |
| `SYNC_INTERVAL_SECONDS` | Fallback delay between sync attempts when ACME renewal metadata is unavailable (default:`86400`) |
| `WEB_PORT`              | Port for the web dashboard (default:`8080`)                                                      |
| `TZ`                    | Timezone (default:`UTC`). Preferably use your own timezone.                                      |

### Example `.env`

```env
DATA_DIR=/opt/docker-data
CERT_UID=1000
CERT_GID=1000
ACME_ACCOUNT_EMAIL=admin@example.com
SYNC_INTERVAL_SECONDS=86400
TZ=Europe/Ljubljana
CF_API_TOKEN=your-cloudflare-api-token
CF_ACCOUNT_ID=your-cloudflare-account-id
```

## Supported Architectures

The published container images include runnable manifests for:

| Architecture    | Docker platform |
| --------------- | --------------- |
| x86_64 / AMD64  | `linux/amd64` |
| ARM64 / AArch64 | `linux/arm64` |

This means you can run the stack on a Raspberry Pi with a 64-bit OS. This has been tested with Ubuntu Server 64-bit running on Raspberry Pi 3B. Please report other setups, whether your deployment is successful or not.

Other Linux architectures may work with a local image build if the Alpine packages used by the Dockerfiles are available for that platform.

## Directory Structure

After first run, the following directories are created under `${DATA_DIR}/cert-updater/`:

```
cert-updater/
├── config/          # settings.yml configuration and users.json credentials
├── state/           # acme.sh state and certificates
├── export/          # Exported certificates by domain (key.pem, cert.pem)
│   ├── example.com/
│   └── site.example.com/
├── ssh/             # SSH keys (auto-generated)
├── ssh-runtime/     # Runtime SSH data (known_hosts per host)
│   ├── router/      # known_hosts for 'router' host
│   └── vps/         # known_hosts for 'vps' host
```

## settings.yml Configuration

`settings.yml` represents your infrastructure. Hosts contain and serve the certificates, so define their SSH destination and reload command. Certificates represent the domains you are maintaining: specify the domain name, the host that receives the certificate files, the destination directory, the key strength, and the DNS challenge settings.

Instead of literal token and account ID values, use environment variable references such as `${CF_API_TOKEN}` or `${DUCKDNS_TOKEN}`.

Place your `settings.yml` in `${DATA_DIR}/cert-updater/config/`. See `config/settings.yml.example` for reference.

### Structure

The configuration has three top-level sections: `webui` (dashboard options), `hosts` (deployment targets), and `domains` (certificates). The `webui` section is optional.

```yaml
# Web dashboard options
webui:
  subpath: ""                     # Optional; use certs to serve the UI at /certs/

# Host definitions - reusable across domains
hosts:
  router:                         # Host identifier (referenced by domains)
    url: root@192.168.1.1         # SSH destination (required)
    transfer: scp                 # Transfer method: scp (default) or rsync
    reload: service restart_nginx # Command to reload service (required)

  vps:
    url: deploy@vps.example.com
    transfer: rsync
    reload: systemctl reload nginx

  my-uncles-lawnmower:            # define your own host identifiers
    url: access@uncle.org
    transfer: rsync
    reload: systemctl reload nginx

# Domain certificates
domains:
  - name: example.com             # Domain name (required)
    keylength: ec-256             # Key type: ec-256, ec-384, 2048, 4096 (required)
    host: router                  # Reference to hosts section (required)
    dest: /opt/certs/example.com  # Remote directory for certificates (required)
    dns:                          # DNS challenge configuration (required)
      provider: cf                # DNS provider: cf or duckdns
      env:                        # Environment variables for the DNS provider
        CF_Token: ${CF_API_TOKEN}
        CF_Account_ID: ${CF_ACCOUNT_ID}
  - name: example.duckdns.org
    keylength: ec-256
    host: vps                     # reference to hosts.vps
    dest: /jffs/nginx/example
    dns:
      provider: duckdns
      env:
        DuckDNS_Token: ${DUCKDNS_TOKEN}
  - name: uncle.duckdns.org
    keylength: ec-256
    host: my-uncles-lawnmower     # the schema enforces reference to the defined hosts
    dest: /uncle/example
    dns:
      provider: duckdns
      env:
        DuckDNS_Token: ${DUCKDNS_TOKEN}        
```

### DNS Providers

The `dns.provider` value is passed to acme.sh as `dns_<provider>`. The dashboard editor and validation schema currently allow these providers:

Currently supported:

| Provider   | `dns.provider` | Required Environment Variables      |
| ---------- | ---------------- | ----------------------------------- |
| Cloudflare | `cf`           | `CF_API_TOKEN`, `CF_ACCOUNT_ID` |
| DuckDNS    | `duckdns`      | `DUCKDNS_TOKEN`                   |

Other acme.sh DNS providers are not enabled in the dashboard schema yet. Support could be added in future releases:

| Provider        | `dns.provider` | Required Environment Variables                   |
| --------------- | ---------------- | ------------------------------------------------ |
| Amazon Route 53 | `aws`          | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |
| DigitalOcean    | `dgon`         | `DO_API_KEY`                                   |

See the [acme.sh DNS API documentation](https://github.com/acmesh-official/acme.sh/wiki/dnsapi) for upstream provider names if you want to extend this project.

### Transfer Methods

- **`scp`** (default): Uses legacy SCP protocol. Works on minimal systems like OpenWrt/ASUS-WRT that don't have sftp-server.
- **`rsync`**: Uses rsync for efficient incremental transfers. Requires rsync on the target host.

## Target Host SSH Setup

The init container automatically generates an SSH key pair on first run. The private key stays in `${DATA_DIR}/cert-updater/ssh/id_ed25519` and is mounted read-only into the `cert-updater` container. You need to add the matching public key to each target host that will receive certificates.

The commands in this section are run from your Docker host (or from any admin machine that can SSH to the target host), not from the target host itself. They connect to the target host and append the generated public key to the target user's authorized keys file.

### 1. Get the Public Key

After signing in to the dashboard, open **SSH Key** to copy the generated public key and host-specific setup commands.

You can also view the generated public key on the Docker host:

```bash
cat ${DATA_DIR}/cert-updater/ssh/id_ed25519.pub
```

Or check the `cert-updater-init` container logs:

```bash
docker logs cert-updater-init
```

### 2. Add to Target Host from the Docker Host

#### Standard Linux (OpenSSH)

```bash
# Copy key to target
ssh-copy-id -i ${DATA_DIR}/cert-updater/ssh/id_ed25519.pub user@target-host

# Or manually from the Docker host
ssh user@target-host "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys" < ${DATA_DIR}/cert-updater/ssh/id_ed25519.pub
```

#### OpenWrt / ASUS-WRT Merlin (Dropbear)

For the root user (UID 0):

```bash
ssh root@router "cat >> /etc/dropbear/authorized_keys" < ${DATA_DIR}/cert-updater/ssh/id_ed25519.pub
ssh root@router "chmod 600 /etc/dropbear/authorized_keys"
```

For non-root users:

```bash
ssh user@router "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys" < ${DATA_DIR}/cert-updater/ssh/id_ed25519.pub
ssh user@router "chmod 600 ~/.ssh/authorized_keys"
```

> **Important**: Dropbear rejects keys from world-writable files. Ensure permissions are `600`.

### 3. Test Connection

Run the test from the Docker host:

```bash
ssh -i ${DATA_DIR}/cert-updater/ssh/id_ed25519 user@target-host "echo success"
```

A successful deployment WILL NOT ask for password.

## Sync Schedule

The worker performs one sync immediately on startup, then keeps running a lightweight shell loop inside the container.

After each sync, the loop reads acme.sh renewal metadata for every configured domain and sleeps until the earliest reported renewal time. acme.sh still decides whether a certificate is actually due for renewal, so non-due certificates are skipped safely.

Admin users can click **Run Now** in the dashboard to request an immediate sync. This interrupts the current sleep and runs the normal backend sync path once; it does not automatically run every time `settings.yml` is saved.

If renewal metadata is not available yet, the worker falls back to `SYNC_INTERVAL_SECONDS`. To change that fallback, set it in your `.env`:

```
SYNC_INTERVAL_SECONDS=86400
```

Restart the worker after changing the interval. Sync activity is written directly to the container logs:

```bash
docker logs -f cert-updater
```

## Manual Sync

To manually trigger certificate sync:

```bash
docker exec cert-updater /cert-updater/bin/sync-certs.sh
```

## Troubleshooting

### Permission Denied on SSH

- Ensure the public key is in the correct file on the target host
- Check file permissions: `authorized_keys` must be `600`
- Verify the user matches the relevant `hosts.<name>.url` value in `settings.yml`

### sftp-server Not Found

Use `transfer: scp` in `settings.yml` for minimal systems without sftp-server.

### Certificate Not Renewing

acme.sh skips renewal if the certificate is not due (>30 days remaining). This is normal behavior. Force renewal with:

```bash
docker exec cert-updater acme.sh --renew -d example.com --ecc --force
```

### Container Keeps Restarting

Check logs for errors:

```bash
docker logs cert-updater
```

- Common issues:
- Missing `settings.yml`
- Invalid YAML syntax
- Missing required fields

## License

MIT
