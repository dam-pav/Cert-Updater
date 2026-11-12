"""Install the updater public key using a one-time SSH password."""

import json
import os
import re
import shlex
import signal
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path


class SshSetupError(Exception):
    """A setup failure safe to return to the browser."""


def log_setup_event(host, stage, password="", **fields):
    """Emit one bounded JSON record to the worker's container logs."""

    def clean(value):
        text = str(value)
        if isinstance(password, str) and password:
            text = text.replace(password, "[password redacted]")
        text = re.sub(
            r"-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----",
            "[private key redacted]",
            text,
            flags=re.DOTALL,
        )
        return text[:2000]

    record = {
        "time": datetime.now(UTC).isoformat(),
        "host": clean(host),
        "stage": stage,
        **{name: clean(value) for name, value in fields.items()},
    }
    print("SSH key setup " + json.dumps(record), file=sys.stderr, flush=True)


# Only POSIX shell and tools available on BusyBox routers are required remotely.
# Detect the serving daemon through process ancestry, rather than the presence of
# a binary: routers can run OpenSSH and Dropbear on different ports.
INSTALL_SCRIPT = r"""
set -eu
umask 077
fail() { printf 'ACME_ERROR=%s\n' "$1"; exit 1; }
printf 'ACME_LOGIN=ok\nACME_STAGE=detect\n'
uid=$(id -u)
platform=$(uname -s)
server=unknown
pid=$$
for step in 1 2 3 4 5 6; do
    [ -r "/proc/$pid/comm" ] || break
    comm=$(cat "/proc/$pid/comm")
    case "$comm" in
        dropbear*) server=dropbear; break ;;
        sshd*) server=openssh; break ;;
    esac
    pid=$(awk '/^PPid:/ {print $2}' "/proc/$pid/status")
    [ -n "$pid" ] && [ "$pid" != 0 ] || break
done
if [ -f /etc/openwrt_release ]; then
    platform=OpenWrt
elif command -v nvram >/dev/null 2>&1 && [ -n "$(nvram get productid)" ] &&
     [ -n "$(nvram get firmver)" ]; then
    platform=ASUS-WRT
fi
persist=none
if [ -n "$override" ]; then
    path=$override
elif [ "$server" = dropbear ] && [ "$platform" = OpenWrt ] && [ "$uid" = 0 ]; then
    path=/etc/dropbear/authorized_keys
elif [ "$server" = dropbear ] && [ "$platform" = ASUS-WRT ] && [ "$uid" = 0 ]; then
    path=/root/.ssh/authorized_keys
    persist=nvram
else
    case "${HOME:-}" in /*) ;; *) fail 'Cannot detect the home directory. Set an absolute authorized-key path.' ;; esac
    path=$HOME/.ssh/authorized_keys
fi
if [ "$server" = dropbear ] && [ "$platform" = ASUS-WRT ] &&
   [ "$uid" = 0 ] && [ "$path" = /root/.ssh/authorized_keys ]; then persist=nvram; fi
printf 'ACME_PLATFORM=%s\nACME_SERVER=%s\nACME_UID=%s\nACME_PATH=%s\n' "$platform" "$server" "$uid" "$path"

# Preserve firmware-managed keys across restarts. Merlin encodes newlines as >
# and reads sshd_authkeys into a 3500-byte buffer (including its NUL terminator).
if [ "$persist" = nvram ]; then
    printf 'ACME_STAGE=persist-router-settings\n'
    stored=$(nvram get sshd_authkeys)
    persistent_key=$(printf '%s' "$key" | tr '>' ' ')
    if ! printf '%s\n' "$stored" | tr '>' '\n' | awk -v blob="$blob" '
        {for (i=1; i<=NF; i++) if ($i == blob) found=1} END {exit !found}'; then
        if [ -n "$stored" ]; then stored="$stored>$persistent_key"; else stored=$persistent_key; fi
        [ "$(printf '%s' "$stored" | wc -c)" -le 3499 ] || fail 'Router authorized keys exceed the firmware limit. Remove unused keys in the router UI first.'
        nvram set "sshd_authkeys=$stored" || fail 'Could not update router authorized keys.'
    fi
    [ "$(printf '%s' "$stored" | wc -c)" -le 3499 ] || fail 'Router authorized keys exceed the firmware limit. Remove unused keys in the router UI first.'
    # Commit even on retry: an earlier request may have set RAM successfully but
    # failed to save it to flash.
    nvram commit || fail 'Could not persist router authorized keys.'
fi
printf 'ACME_STAGE=write-authorized-key\n'
dir=$(dirname "$path")
[ ! -d "$path" ] || fail 'The authorized-key path refers to a directory.'
if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] || fail 'The authorized-key path is not a regular file.'
fi
mkdir -p "$dir" || fail 'Could not create the authorized-key directory.'
# Do not change permissions of shared directories such as /etc or /home.
case "$dir" in
    */.ssh|/etc/dropbear)
        chmod 700 "$dir" || fail 'Could not set authorized-key directory permissions.' ;;
esac
touch "$path" || fail 'Could not write the authorized-key file.'
chmod 600 "$path" || fail 'Could not set authorized-key permissions.'
if ! awk -v blob="$blob" '
    {for (i=1; i<=NF; i++) if ($i == blob) found=1} END {exit !found}' "$path"; then
    # Leading newline also handles a pre-existing final line without a newline.
    printf '\n%s\n' "$key" >> "$path" || fail 'Could not append the public key.'
fi
printf 'ACME_PERSIST=%s\n' "$persist"
"""


def install_script(public_key, override):
    fields = public_key.split()
    if len(fields) < 2 or fields[0] != "ssh-ed25519" or "\n" in public_key:
        raise SshSetupError("The generated SSH public key is invalid.")
    return (
        f"key={shlex.quote(public_key)}\n"
        f"blob={shlex.quote(fields[1])}\n"
        f"override={shlex.quote(override)}\n" + INSTALL_SCRIPT
    )


def metadata(output):
    return dict(
        line.removeprefix("ACME_").split("=", 1)
        for line in output.splitlines()
        if line.startswith("ACME_") and "=" in line
    )


def run_password_ssh(command, password, script):
    """Feed sshpass through an inherited pipe; never argv, environment or disk."""
    read_fd, write_fd = os.pipe()
    try:
        os.write(write_fd, password.encode() + b"\n")
        os.close(write_fd)
        write_fd = None
        args = ["sshpass", "-d", str(read_fd), *command]
        with subprocess.Popen(
            args,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            pass_fds=(read_fd,),
            start_new_session=True,
        ) as process:
            try:
                stdout, stderr = process.communicate(script, timeout=30)
            except subprocess.TimeoutExpired as exc:
                # sshpass starts ssh as a child. Stop both, including any open
                # output pipes, rather than leaving the SSH session running.
                os.killpg(process.pid, signal.SIGKILL)
                exc.stdout, exc.stderr = process.communicate()
                raise
            return subprocess.CompletedProcess(args, process.returncode, stdout, stderr)
    finally:
        os.close(read_fd)
        if write_fd is not None:
            os.close(write_fd)


def connection_error(result):
    output = result.stderr.lower()
    details = metadata(result.stdout)
    if details.get("LOGIN") == "ok" or "UID" in details:
        return "SSH login succeeded, but remote key installation failed. Check the worker logs for the failing operation and target permissions."
    if (
        "host key verification failed" in output
        or "remote host identification has changed" in output
    ):
        return "SSH host key does not match the trusted key. Check the target's identity before updating its trusted key."
    if result.returncode == 5 or (
        result.returncode == 255
        and re.search(
            r"permission denied\s*\([^)]*(?:password|publickey|keyboard-interactive)[^)]*\)",
            output,
        )
    ):
        return "SSH authentication failed. Check the password and whether password login is enabled."
    return "SSH connection or remote setup failed. Check the target address, SSH access and account permissions."


def install_ssh_key(
    host_name, target, password, override, public_key_path, runtime_dir
):
    """Log installation progress and failures without retaining the password."""
    stage = "validation"

    def report(next_stage, **fields):
        nonlocal stage
        stage = next_stage
        log_setup_event(host_name, stage, password, **fields)

    report("validation", status="started")
    try:
        return _install_ssh_key(
            host_name, target, password, override, public_key_path, runtime_dir, report
        )
    except Exception as exc:
        report(
            stage,
            status="failed",
            error=str(exc),
            error_type=type(exc).__name__,
            cause=str(exc.__cause__ or ""),
            diagnostic=getattr(exc.__cause__, "stderr", "") or "",
        )
        raise


def _install_ssh_key(
    host_name, target, password, override, public_key_path, runtime_dir, report
):
    if (
        not isinstance(host_name, str)
        or not re.fullmatch(r"[A-Za-z0-9_.-]+", host_name)
        or host_name in (".", "..")
    ):
        raise SshSetupError(
            "Host name must contain only letters, numbers, dots, underscores or hyphens."
        )
    if (
        not isinstance(target, str)
        or not target
        or target.startswith("-")
        or any(c.isspace() or ord(c) < 32 for c in target)
    ):
        raise SshSetupError("The configured SSH target is invalid.")
    if (
        not isinstance(password, str)
        or not password
        or len(password.encode()) > 1024
        or any(c in password for c in "\r\n\0")
    ):
        raise SshSetupError(
            "Enter a password of at most 1024 bytes without line breaks."
        )
    if not isinstance(override, str) or (
        override
        and (
            not override.startswith("/")
            or os.path.basename(override) in ("", ".", "..")
            or any(ord(c) < 32 for c in override)
        )
    ):
        raise SshSetupError(
            "The authorized-key path override must be an absolute path without control characters."
        )
    report("local-key", status="reading")
    public_path = Path(public_key_path)
    private_path = public_path.with_suffix("")
    try:
        public_key = public_path.read_text().strip()
        if not private_path.is_file():
            raise SshSetupError("The updater SSH private key was not found.")
    except OSError as exc:
        raise SshSetupError("The updater SSH key could not be read.") from exc
    script = install_script(public_key, override)
    report("host-key-storage", status="preparing")
    known_hosts = Path(runtime_dir) / host_name / "known_hosts"
    known_hosts.parent.mkdir(parents=True, exist_ok=True)
    common = [
        "ssh",
        "-F",
        "/dev/null",
        "-T",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        f"UserKnownHostsFile={known_hosts}",
        "-o",
        "ConnectTimeout=8",
        "-o",
        "ConnectionAttempts=1",
        "-o",
        "ControlMaster=no",
        "-o",
        "ControlPath=none",
    ]
    try:
        report("password-login-and-install", status="connecting", target=target)
        result = run_password_ssh(
            common
            + [
                "-o",
                "BatchMode=no",
                "-o",
                "PubkeyAuthentication=no",
                "-o",
                "PreferredAuthentications=password,keyboard-interactive",
                "-o",
                "NumberOfPasswordPrompts=1",
                target,
                "sh -s",
            ],
            password,
            script,
        )
        details = metadata(result.stdout)
        report(
            "password-login-and-install",
            status="finished",
            exit_code=result.returncode,
            diagnostic=result.stderr,
            remote_stage=details.get("STAGE", "unknown"),
            **{
                name.lower(): details[name]
                for name in ("PLATFORM", "SERVER", "UID", "PATH", "PERSIST", "ERROR")
                if name in details
            },
        )
        if result.returncode:
            raise SshSetupError(details.get("ERROR") or connection_error(result))
        if not details.get("PATH") or "PERSIST" not in details:
            raise SshSetupError(
                "The remote installer did not complete. Check that the account permits shell commands."
            )
        report("key-only-verification", status="connecting", path=details["PATH"])
        verified = subprocess.run(
            common
            + [
                "-i",
                str(private_path),
                "-o",
                "IdentitiesOnly=yes",
                "-o",
                "IdentityAgent=none",
                "-o",
                "BatchMode=yes",
                "-o",
                "PreferredAuthentications=publickey",
                "-o",
                "PasswordAuthentication=no",
                "-o",
                "KbdInteractiveAuthentication=no",
                target,
                "true",
            ],
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        report(
            "key-only-verification",
            status="finished",
            exit_code=verified.returncode,
            diagnostic=verified.stderr,
        )
        if verified.returncode:
            raise SshSetupError(
                f"Key installed at {details['PATH']}, but key-only login failed. "
                "Check the server's authorized-key path, key algorithm support and account restrictions. "
                "You can retry with an authorized-key path override."
            )
    except subprocess.TimeoutExpired as exc:
        raise SshSetupError(
            "SSH setup timed out. The key may have been installed; check the target before retrying."
        ) from exc
    except OSError as exc:
        raise SshSetupError(
            "SSH setup could not run. Check that ssh and sshpass are installed and runtime storage is writable."
        ) from exc
    report("complete", status="success", path=details["PATH"])
    return {
        "status": "ok",
        "message": f"Key installed at {details['PATH']}. Key-only login verified.",
        "platform": details.get("PLATFORM", "unknown"),
        "ssh_server": details.get("SERVER", "unknown"),
        "uid": details.get("UID", ""),
        "authorized_keys_path": details["PATH"],
        "persistence": details["PERSIST"],
        "warning": (
            "Custom key paths on ASUS-WRT may be replaced after a restart; persistence was not configured."
            if details.get("PLATFORM") == "ASUS-WRT" and details["PERSIST"] != "nvram"
            else ""
        ),
    }
