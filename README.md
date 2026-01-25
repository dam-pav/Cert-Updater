# ACME Worker

A Docker-based automatic SSL/TLS certificate manager using [acme.sh](https://github.com/acmesh-official/acme.sh) with Let's Encrypt. Automatically issues, renews, and deploys certificates to remote hosts via SSH.

## Features

- **Automatic certificate issuance and renewal** via Let's Encrypt
- **DNS-01 challenge support** for wildcard certificates and internal servers
- **Remote deployment** via SSH (scp or rsync)
- **Multiple domains** configured via a single YAML file
- **Non-root container** execution with configurable UID/GID
- **Cron-based scheduling** for automatic renewals

## Quick Start

1. Create a `.env` file with your configuration
2. Create `domains.yml` in your config directory
3. Run `docker-compose up -d`
4. Add the generated SSH public key to your target hosts

## Environment Variables

### Required

| Variable | Description |
|----------|-------------|
| `DATA_DIR` | Base directory for persistent data (e.g., `/opt/docker-data`) |
| `ACME_UID` | User ID for the worker container (e.g., `1000`) |
| `ACME_GID` | Group ID for the worker container (e.g., `1000`) |

### Optional

| Variable | Description |
|----------|-------------|
| `ACME_ACCOUNT_EMAIL` | Email for Let's Encrypt notifications (expiry warnings) |
| `CF_API_TOKEN` | Cloudflare API token (if using Cloudflare DNS) |
| `CF_ACCOUNT_ID` | Cloudflare Account ID (if using Cloudflare DNS) |
| `DUCKDNS_TOKEN` | DuckDNS token (if using DuckDNS) |
| `TZ` | Timezone (default: `UTC`) |

### Example `.env`

```env
DATA_DIR=/opt/docker-data
ACME_UID=1000
ACME_GID=1000
ACME_ACCOUNT_EMAIL=admin@example.com
CF_API_TOKEN=your-cloudflare-api-token
CF_ACCOUNT_ID=your-cloudflare-account-id
```

## Directory Structure

After first run, the following directories are created under `${DATA_DIR}/acme/`:

```
acme/
├── config/          # domains.yml configuration
├── state/           # acme.sh state and certificates
├── export/          # Exported certificates (key.pem, cert.pem)
├── ssh/             # SSH keys (auto-generated)
├── ssh-runtime/     # Runtime SSH data (known_hosts)
├── crontabs/        # Cron schedule (editable)
└── logs/            # Cron logs
```

## domains.yml Configuration

Place your `domains.yml` in `${DATA_DIR}/acme/config/`. See `config/domains.yml.example` for reference.

### Structure

```yaml
domains:
  - name: example.com           # Domain name (required)
    keylength: ec-256           # Key type: ec-256, ec-384, 2048, 4096 (required)

    dns:                        # DNS challenge configuration (required)
      provider: cf              # DNS provider: cf, duckdns, etc.
      env:                      # Environment variables for the DNS provider
        CF_Token: ${CF_API_TOKEN}
        CF_Account_ID: ${CF_ACCOUNT_ID}

    host:                       # Deployment target (required)
      host_url: user@host       # SSH destination (required)
      dest: /path/to/certs      # Remote directory for certificates (required)
      reload: systemctl reload nginx  # Command to reload service (required)
      transfer: scp             # Transfer method: scp (default) or rsync (optional)
```

### DNS Providers

The `dns.provider` value corresponds to acme.sh DNS API plugins. Common providers:

| Provider | `dns.provider` | Required Environment Variables |
|----------|----------------|-------------------------------|
| Cloudflare | `cf` | `CF_Token`, `CF_Account_ID` |
| DuckDNS | `duckdns` | `DUCKDNS_TOKEN` |
| Route53 | `aws` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |
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
cat ${DATA_DIR}/acme/ssh/id_ed25519.pub
```

Or check the `acme-init` container logs:

```bash
docker logs acme-init
```

### 2. Add to Target Host

#### Standard Linux (OpenSSH)

```bash
# Copy key to target
ssh-copy-id -i ${DATA_DIR}/acme/ssh/id_ed25519.pub user@target-host

# Or manually
ssh user@target-host "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys" < ${DATA_DIR}/acme/ssh/id_ed25519.pub
```

#### OpenWrt / ASUS-WRT Merlin (Dropbear)

For the root user (UID 0):
```bash
ssh root@router "cat >> /etc/dropbear/authorized_keys" < ${DATA_DIR}/acme/ssh/id_ed25519.pub
ssh root@router "chmod 600 /etc/dropbear/authorized_keys"
```

For non-root users:
```bash
ssh user@router "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys" < ${DATA_DIR}/acme/ssh/id_ed25519.pub
ssh user@router "chmod 600 ~/.ssh/authorized_keys"
```

> **Important**: Dropbear rejects keys from world-writable files. Ensure permissions are `600`.

### 3. Test Connection

```bash
ssh -i ${DATA_DIR}/acme/ssh/id_ed25519 user@target-host "echo success"
```

## Cron Schedule

By default, certificates are renewed on the 1st of each month at 3:00 AM. 

To modify the schedule, edit:
```bash
${DATA_DIR}/acme/crontabs/acme
```

The file uses standard cron format:
```
# minute hour day month weekday command
0 3 1 * * /acme/bin/sync-certs.sh >> /var/log/cron/acme.log 2>&1
```

Changes take effect after container restart.

## Manual Sync

To manually trigger certificate sync:

```bash
docker exec acme-worker /acme/bin/sync-certs.sh
```

## Troubleshooting

### Permission Denied on SSH

- Ensure the public key is in the correct file on the target host
- Check file permissions: `authorized_keys` must be `600`
- Verify the user matches `host_url` in `domains.yml`

### sftp-server Not Found

Use `transfer: scp` in `domains.yml` for minimal systems without sftp-server.

### Certificate Not Renewing

acme.sh skips renewal if the certificate is not due (>30 days remaining). This is normal behavior. Force renewal with:

```bash
docker exec acme-worker acme.sh --renew -d example.com --force
```

### Container Keeps Restarting

Check logs for errors:
```bash
docker logs acme-worker
```

Common issues:
- Missing `domains.yml`
- Invalid YAML syntax
- Missing required fields

## License

MIT
