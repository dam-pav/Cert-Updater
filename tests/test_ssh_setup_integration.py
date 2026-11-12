"""Real SSH tests in an isolated container (never on a router).

docker build -f tests/Dockerfile.ssh-setup -t cert-updater-ssh-tests .
docker run --rm cert-updater-ssh-tests
"""

import os
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bin"))
import ssh_setup
from ssh_setup import SshSetupError, install_ssh_key

pytestmark = pytest.mark.skipif(
    os.environ.get("SSH_SETUP_INTEGRATION") != "1",
    reason="Run inside tests/Dockerfile.ssh-setup; these tests change container accounts and firmware files.",
)
PASSWORD = "temporary 'password' $(literal)!"


@pytest.fixture
def identity(tmp_path):
    subprocess.run(
        [
            "ssh-keygen",
            "-q",
            "-t",
            "ed25519",
            "-N",
            "",
            "-f",
            str(tmp_path / "id_ed25519"),
        ],
        check=True,
    )
    return tmp_path / "id_ed25519.pub"


@pytest.fixture
def account():
    subprocess.run(["adduser", "-D", "sshsetup"], check=True)
    subprocess.run(
        ["chpasswd"],
        input=f"sshsetup:{PASSWORD}\nroot:{PASSWORD}\n",
        text=True,
        check=True,
    )
    # Router administrators can have UID 0 despite a username other than root.
    passwd = Path("/etc/passwd")
    shadow = Path("/etc/shadow")
    passwd_original, shadow_original = passwd.read_text(), shadow.read_text()
    passwd.write_text(passwd_original + "homologue:x:0:0:Router admin:/root:/bin/sh\n")
    root_shadow = next(
        line for line in shadow_original.splitlines() if line.startswith("root:")
    )
    shadow.write_text(
        shadow_original + "homologue:" + root_shadow.split(":", 1)[1] + "\n"
    )
    yield
    passwd.write_text(passwd_original)
    shadow.write_text(shadow_original)
    subprocess.run(["deluser", "--remove-home", "sshsetup"], check=True)


@pytest.fixture
def start_server(tmp_path, account):
    processes = []

    def start(kind="openssh", custom_path=None):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        host_key = tmp_path / f"hostkey-{port}"
        if kind == "openssh":
            subprocess.run(
                ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(host_key)],
                check=True,
            )
            config = tmp_path / f"sshd-{port}.conf"
            config.write_text(
                f"Port {port}\nListenAddress 127.0.0.1\nHostKey {host_key}\n"
                "PasswordAuthentication yes\nUsePAM no\nPermitRootLogin yes\n"
                f"AuthorizedKeysFile {custom_path or '.ssh/authorized_keys'}\n"
                f"PidFile {tmp_path}/sshd-{port}.pid\n"
            )
            command = ["/usr/sbin/sshd", "-D", "-e", "-f", str(config)]
        else:
            subprocess.run(
                ["dropbearkey", "-t", "ed25519", "-f", str(host_key)],
                check=True,
                capture_output=True,
            )
            command = [
                "dropbear",
                "-F",
                "-E",
                "-r",
                str(host_key),
                "-p",
                f"127.0.0.1:{port}",
                "-P",
                str(tmp_path / "dropbear.pid"),
            ]
        log = (tmp_path / f"server-{port}.log").open("w+")
        process = subprocess.Popen(command, stdout=log, stderr=log)
        processes.append((process, log))
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if process.poll() is not None:
                log.seek(0)
                pytest.fail(log.read())
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                    return port
            except OSError:
                time.sleep(0.02)
        pytest.fail("SSH fixture did not start")

    yield start
    for process, log in processes:
        process.terminate()
        process.wait(timeout=5)
        log.close()


def setup(identity, tmp_path, port, user="sshsetup", **kwargs):
    return install_ssh_key(
        "router",
        f"ssh://{user}@127.0.0.1:{port}",
        kwargs.get("password", PASSWORD),
        kwargs.get("override", ""),
        identity,
        tmp_path / "runtime",
    )


def test_openssh_nonroot_install_and_repeat(identity, tmp_path, start_server):
    port = start_server()
    result = setup(identity, tmp_path, port)
    assert result["ssh_server"] == "openssh"
    assert result["uid"] != "0"
    assert result["authorized_keys_path"] == "/home/sshsetup/.ssh/authorized_keys"
    path = Path(result["authorized_keys_path"])
    original = path.read_text()
    assert identity.read_text().strip() in original
    setup(identity, tmp_path, port)
    assert path.read_text() == original
    assert path.stat().st_mode & 0o777 == 0o600


def test_wrong_password_cannot_install(identity, tmp_path, start_server):
    with pytest.raises(SshSetupError, match="authentication failed"):
        setup(identity, tmp_path, start_server(), password="incorrect")
    assert not Path("/home/sshsetup/.ssh/authorized_keys").exists()


def test_custom_openssh_path_requires_override(identity, tmp_path, start_server):
    port = start_server(custom_path="custom_authorized_keys")
    with pytest.raises(SshSetupError, match="key-only login failed"):
        setup(identity, tmp_path, port)
    result = setup(
        identity, tmp_path, port, override="/home/sshsetup/custom_authorized_keys"
    )
    assert result["status"] == "ok"


def test_changed_host_key_is_rejected(identity, tmp_path, start_server):
    port = start_server()
    known = tmp_path / "runtime/router/known_hosts"
    known.parent.mkdir(parents=True)
    public_key = identity.read_text().split()
    known.write_text(f"[127.0.0.1]:{port} {public_key[0]} {public_key[1]}\n")
    with pytest.raises(SshSetupError, match="does not match"):
        setup(identity, tmp_path, port)
    assert not Path("/home/sshsetup/.ssh/authorized_keys").exists()


def test_dropbear_nonroot_uses_home_directory(identity, tmp_path, start_server):
    result = setup(identity, tmp_path, start_server("dropbear"))
    assert result["ssh_server"] == "dropbear"
    assert result["authorized_keys_path"] == "/home/sshsetup/.ssh/authorized_keys"


@pytest.fixture
def missing_router_tools(account, tmp_path):
    """Model firmware that ships BusyBox without utility symlinks such as id."""
    moved = []
    try:
        for name in ("id", "uname", "awk", "tr", "wc", "mkdir", "chmod"):
            for prefix in ("/bin", "/usr/bin", "/sbin", "/usr/sbin"):
                command = Path(prefix) / name
                if command.is_symlink() or command.exists():
                    backup = tmp_path / f"utility-{len(moved)}"
                    command.rename(backup)
                    moved.append((command, backup))
        check = subprocess.run(
            ["sh", "-c", "id -u"], capture_output=True, text=True, check=False
        )
        assert check.returncode == 127
        assert "not found" in check.stderr
        yield
    finally:
        for command, backup in reversed(moved):
            backup.rename(command)


def test_dropbear_install_without_router_utility_symlinks(
    identity, tmp_path, start_server, missing_router_tools
):
    result = setup(identity, tmp_path, start_server("dropbear"))
    assert result["status"] == "ok"
    assert result["uid"] != "0"
    assert result["authorized_keys_path"] == "/home/sshsetup/.ssh/authorized_keys"


@pytest.fixture
def restricted_router_shell(missing_router_tools, monkeypatch):
    """Only file-writing applets work; command -v and help probes do not."""
    with tempfile.TemporaryDirectory(prefix="router-shell-", dir="/tmp") as directory:
        path = Path(directory)
        path.chmod(0o755)
        busybox = path / "busybox"
        busybox.write_text("""#!/bin/sh
applet=$1
shift
[ "${1:-}" != --help ] || exit 1
case "$applet" in
    mkdir|chmod) /bin/busybox "$applet" "$@" ;;
    *) printf '%s: applet not found\n' "$applet" >&2; exit 127 ;;
esac
""")
        busybox.chmod(0o755)
        monkeypatch.setattr(
            ssh_setup,
            "INSTALL_SCRIPT",
            "command() { return 127; }\n"
            f"PATH={shlex.quote(directory)}:$PATH\n" + ssh_setup.INSTALL_SCRIPT,
        )
        yield


@pytest.fixture
def root_keys():
    root_ssh = Path("/root/.ssh")
    assert not root_ssh.exists(), "Router fixtures require a disposable container"
    yield root_ssh
    if root_ssh.is_symlink():
        root_ssh.unlink()
    elif root_ssh.exists():
        shutil.rmtree(root_ssh)


def test_openwrt_root_uses_global_key_file(identity, tmp_path, start_server, root_keys):
    marker = Path("/etc/openwrt_release")
    directory = Path("/etc/dropbear")
    marker.write_text("DISTRIB_ID=OpenWrt\n")
    directory.mkdir(mode=0o700, exist_ok=True)
    # Upstream Dropbear is unpatched. This symlink emulates OpenWrt's root-key
    # lookup while still exercising a real Dropbear password and public-key login.
    root_keys.symlink_to(directory)
    try:
        result = setup(identity, tmp_path, start_server("dropbear"), user="homologue")
        assert result["platform"] == "OpenWrt"
        assert result["authorized_keys_path"] == "/etc/dropbear/authorized_keys"
    finally:
        marker.unlink()
        shutil.rmtree(directory)


def test_asuswrt_persists_keys_and_preserves_existing_nvram(
    identity, tmp_path, start_server, root_keys, restricted_router_shell
):
    nvram = Path("/usr/bin/nvram")
    stored = tmp_path / "sshd_authkeys"
    committed = tmp_path / "committed"
    stored.write_text("ssh-ed25519 OTHER existing-key")
    nvram.write_text(f"""#!/bin/sh
case "$1:$2" in
  get:productid) echo RT-TEST ;;
  get:firmver) echo 3006 ;;
  get:sshd_authkeys) cat '{stored}' ;;
  set:sshd_authkeys=*) printf '%s' "${{2#sshd_authkeys=}}" > '{stored}' ;;
  commit:) touch '{committed}' ;;
  *) exit 1 ;;
esac
""")
    nvram.chmod(0o755)
    try:
        port = start_server("dropbear")
        result = setup(identity, tmp_path, port, user="homologue")
        assert result["platform"] == "ASUS-WRT"
        assert result["persistence"] == "nvram"
        assert result["authorized_keys_path"] == "/root/.ssh/authorized_keys"
        assert (
            stored.read_text()
            == "ssh-ed25519 OTHER existing-key>" + identity.read_text().strip()
        )
        assert committed.exists()
        original = stored.read_text()
        # Emulate firmware rebuilding the runtime file after a restart.
        Path(result["authorized_keys_path"]).write_text(
            original.replace(">", "\n") + "\n"
        )
        setup(identity, tmp_path, port, user="homologue")
        assert stored.read_text() == original
        stored.write_text("x" * 3499)
        with pytest.raises(SshSetupError, match="firmware limit"):
            setup(identity, tmp_path, port, user="homologue")
        assert stored.read_text() == "x" * 3499
        unicode_keys = "#" + "é" * 1749
        stored.write_text(unicode_keys)
        with pytest.raises(SshSetupError, match="firmware limit"):
            setup(identity, tmp_path, port, user="homologue")
        assert stored.read_text() == unicode_keys
    finally:
        nvram.unlink()
