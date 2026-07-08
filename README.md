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

## Quick Start

1. Create a `.env` file with your configuration:
   ```env
   DATA_DIR=/path/to/data
   CERT_UID=1000
   CERT_GID=1000
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
4. Start the stack:
   ```bash
   docker compose up -d
   ```
   This pulls `ghcr.io/dam-pav/cert-updater:latest` and `ghcr.io/dam-pav/cert-updater-web:latest`.
5. Add the generated SSH public key to your target hosts (see "Target Host SSH Setup" below)

## Web Dashboard

A built-in dashboard provides a real-time overview of all certificate statuses. Access it at:

```
http://localhost:8080
```

The dashboard displays:
- **Summary cards**: Total, valid, expired, and unknown certificates
- **Domain table**: Domain name, target host, DNS provider, status, last checked, last updated, and next renewal date
- **Auto-refresh**: Updates every 60 seconds
- **Manual refresh**: Click the floating refresh button

Customize the port with the `WEB_PORT` environment variable:

```
WEB_PORT=80
```

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

| Variable | Description |
|----------|-------------|
| `DATA_DIR` | Base directory for persistent data (e.g., `/opt/docker-data`) |
| `CERT_UID` | User ID for the updater container (e.g., `1000`) |
| `CERT_GID` | Group ID for the updater container (e.g., `1000`) |

### Required for Cloudflare provider

| Variable | Description |
|----------|-------------|
| `CF_API_TOKEN` | Cloudflare API token |
| `CF_ACCOUNT_ID` | Cloudflare Account ID |

### Required for DuckDNS provider

| Variable | Description |
|----------|-------------|
| `DUCKDNS_TOKEN` | DuckDNS token (if using DuckDNS) |

### Optional

| Variable | Description |
|----------|-------------|
| `ACME_ACCOUNT_EMAIL` | Email for Let's Encrypt notifications (expiry warnings) |
| `SYNC_INTERVAL_SECONDS` | Fallback delay between sync attempts when ACME renewal metadata is unavailable (default: `86400`) |
| `WEB_PORT` | Port for the web dashboard (default: `8080`) |
| `TZ` | Timezone (default: `UTC`) |

### Example `.env`

```env
DATA_DIR=/opt/docker-data
CERT_UID=1000
CERT_GID=1000
ACME_ACCOUNT_EMAIL=admin@example.com
SYNC_INTERVAL_SECONDS=86400
CF_API_TOKEN=your-cloudflare-api-token
CF_ACCOUNT_ID=your-cloudflare-account-id
```

## Directory Structure

After first run, the following directories are created under `${DATA_DIR}/cert-updater/`:

```
cert-updater/
├── config/          # settings.yml configuration
├── state/           # acme.sh state and certificates
├── export/          # Exported certificates (key.pem, cert.pem)
├── ssh/             # SSH keys (auto-generated)
├── ssh-runtime/     # Runtime SSH data (known_hosts per host)
│   ├── router/      # known_hosts for 'router' host
│   └── vps/         # known_hosts for 'vps' host
```

## settings.yml Configuration
`settings.yml` represents your infrastructure. Hosts contain and serve the certificates - you need to define their location and means of updating. Certificates represent the domains you are maintaining - you need to specify the domain name itself, the host that is holding the certificate files, and the certificate strength. Furthermore, you need to provide infomration on how the ownership of the domain is being challenged.

Instead of using literal values for tokens and account ids you can use use the environment variables. You can use any of them but of course only some of them make actual sense. 

Place your `settings.yml` in `${DATA_DIR}/cert-updater/config/`. See `config/settings.yml.example` for reference.

### Structure

The configuration has two sections: `hosts` (deployment targets) and `domains` (certificates).

```yaml
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

# Domain certificates
domains:
  - name: example.com             # Domain name (required)
    keylength: ec-256             # Key type: ec-256, ec-384, 2048, 4096 (required)
    host: router                  # Reference to hosts section (required)
    dest: /opt/certs/example.com  # Remote directory for certificates (required)

    dns:                          # DNS challenge configuration (required)
      provider: cf                # DNS provider: cf, duckdns, etc.
      env:                        # Environment variables for the DNS provider
        CF_Token: ${CF_API_TOKEN}
        CF_Account_ID: ${CF_ACCOUNT_ID}
```

### DNS Providers

The `dns.provider` value corresponds to acme.sh DNS API plugins. Common providers:

Currently supported:
| Provider | `dns.provider` | Required Environment Variables |
|----------|----------------|-------------------------------|
| Cloudflare | `cf` | `CF_API_TOKEN`, `CF_ACCOUNT_ID` |
| DuckDNS | `duckdns` | `DUCKDNS_TOKEN` |

Could receive support in future releases:
| Provider | `dns.provider` | Required Environment Variables |
|----------|----------------|-------------------------------|
| Amazon Route 53 | `aws` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |
| DigitalOcean | `dgon` | `DO_API_KEY` |

See [acme.sh DNS API documentation](https://github.com/acmesh-official/acme.sh/wiki/dnsapi) for all supported providers.

### Transfer Methods

- **`scp`** (default): Uses legacy SCP protocol. Works on minimal systems like OpenWrt/ASUS-WRT that don't have sftp-server.
- **`rsync`**: Uses rsync for efficient incremental transfers. Requires rsync on the target host.

## Target Host SSH Setup

The init container automatically generates an SSH key pair on first run. You need to add the public key to each target host.

### 1. Get the Public Key

After first run, view the generated public key:

```bash
cat ${DATA_DIR}/cert-updater/ssh/id_ed25519.pub
```

Or check the `cert-updater-init` container logs:

```bash
docker logs cert-updater-init
```

### 2. Add to Target Host

#### Standard Linux (OpenSSH)

```bash
# Copy key to target
ssh-copy-id -i ${DATA_DIR}/cert-updater/ssh/id_ed25519.pub user@target-host

# Or manually
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

```bash
ssh -i ${DATA_DIR}/cert-updater/ssh/id_ed25519 user@target-host "echo success"
```
A successful deployment WILL NOT ask for password.

## Sync Schedule

The worker performs one sync immediately on startup, then keeps running a lightweight shell loop inside the container.

After each sync, the loop reads acme.sh renewal metadata for every configured domain and sleeps until the earliest reported renewal time. acme.sh still decides whether a certificate is actually due for renewal, so non-due certificates are skipped safely.

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
- Verify the user matches `host_url` in `settings.yml`

### sftp-server Not Found

Use `transfer: scp` in `settings.yml` for minimal systems without sftp-server.

### Certificate Not Renewing

acme.sh skips renewal if the certificate is not due (>30 days remaining). This is normal behavior. Force renewal with:

```bash
docker exec cert-updater acme.sh --renew -d example.com --force
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
