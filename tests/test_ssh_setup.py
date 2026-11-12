"""SSH setup behavior, including preservation of existing authorized keys."""

import importlib.util
import json
import os
import subprocess
import sys
import threading
import urllib.error
import urllib.request
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bin"))
import ssh_setup

PUBLIC_KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEOOKMkTIH/OjWfM9Ve+XIOzBTZCwB8OEoMbv3XIizD1 acme-worker"
DETAILS = "ACME_PLATFORM=Linux\nACME_SERVER=openssh\nACME_UID=1000\nACME_PATH=/home/user/.ssh/authorized_keys\nACME_PERSIST=none\n"


@pytest.fixture
def keys(tmp_path):
    private = tmp_path / "id_ed25519"
    private.write_text("private-key-fixture")
    public = tmp_path / "id_ed25519.pub"
    public.write_text(PUBLIC_KEY + "\n")
    return public


def install(keys, tmp_path, **kwargs):
    return ssh_setup.install_ssh_key(
        kwargs.get("host", "router"),
        kwargs.get("target", "homologue@192.168.1.1"),
        kwargs.get("password", "one-time-password"),
        kwargs.get("override", ""),
        keys,
        tmp_path / "runtime",
    )


def test_installer_preserves_keys_and_permissions_and_is_repeatable(tmp_path):
    key_path = tmp_path / "user's $(touch INJECTED) dir" / ".ssh" / "authorized_keys"
    key_path.parent.mkdir(parents=True)
    existing = "restrict ssh-ed25519 OTHER existing-key-without-final-newline"
    key_path.write_text(existing)
    script = ssh_setup.install_script(PUBLIC_KEY, str(key_path))
    for _ in range(2):
        subprocess.run(
            ["sh"],
            input=script,
            text=True,
            check=True,
            capture_output=True,
            cwd=tmp_path,
        )
    assert key_path.read_text() == existing + "\n" + PUBLIC_KEY + "\n"
    assert key_path.stat().st_mode & 0o777 == 0o600
    assert key_path.parent.stat().st_mode & 0o777 == 0o700
    assert not (tmp_path / "INJECTED").exists()


def test_existing_key_with_other_comment_or_options_is_preserved(tmp_path):
    key_path = tmp_path / "authorized_keys"
    key_path.write_text("restrict " + PUBLIC_KEY.rsplit(" ", 1)[0] + " other-comment\n")
    original = key_path.read_text()
    subprocess.run(
        ["sh"],
        input=ssh_setup.install_script(PUBLIC_KEY, str(key_path)),
        text=True,
        check=True,
        capture_output=True,
    )
    assert key_path.read_text() == original


def test_existing_key_options_with_quoted_spaces_and_hash_are_preserved(tmp_path):
    key_path = tmp_path / "authorized_keys"
    original = 'command="echo # restricted",restrict ' + PUBLIC_KEY + "\n"
    key_path.write_text(original)
    subprocess.run(
        ["sh"],
        input=ssh_setup.install_script(PUBLIC_KEY, str(key_path)),
        text=True,
        check=True,
        capture_output=True,
    )
    assert key_path.read_text() == original


def test_commented_public_key_does_not_count_as_installed(tmp_path):
    key_path = tmp_path / "authorized_keys"
    original = "  # " + PUBLIC_KEY + "\n"
    key_path.write_text(original)
    subprocess.run(
        ["sh"],
        input=ssh_setup.install_script(PUBLIC_KEY, str(key_path)),
        text=True,
        check=True,
        capture_output=True,
    )
    assert key_path.read_text() == original + "\n" + PUBLIC_KEY + "\n"


def test_override_cannot_chmod_a_directory(tmp_path):
    target = tmp_path / "shared"
    target.mkdir(mode=0o755)
    result = subprocess.run(
        ["sh"],
        input=ssh_setup.install_script(PUBLIC_KEY, str(target)),
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode != 0
    assert "refers to a directory" in result.stdout
    assert target.stat().st_mode & 0o777 == 0o755


@pytest.mark.parametrize(
    "kwargs",
    [
        {"host": "../escape"},
        {"host": ".."},
        {"target": "-oProxyCommand=bad"},
        {"target": "user@host command"},
        {"password": ""},
        {"password": "bad\npassword"},
        {"override": "relative/path"},
        {"override": "/"},
        {"override": "/tmp/."},
        {"override": "/tmp/keys\nmalformed"},
    ],
)
def test_rejects_invalid_inputs_before_connecting(keys, tmp_path, kwargs):
    with patch.object(ssh_setup, "run_password_ssh") as connect:
        with pytest.raises(ssh_setup.SshSetupError):
            install(keys, tmp_path, **kwargs)
        connect.assert_not_called()


def test_success_requires_a_separate_key_only_connection(keys, tmp_path, capsys):
    with (
        patch.object(
            ssh_setup,
            "run_password_ssh",
            return_value=subprocess.CompletedProcess([], 0, DETAILS, ""),
        ) as password_ssh,
        patch.object(
            ssh_setup.subprocess,
            "run",
            return_value=subprocess.CompletedProcess([], 0, "", ""),
        ) as verify,
    ):
        result = install(keys, tmp_path)
    assert result["status"] == "ok"
    password_command = password_ssh.call_args.args[0]
    verify_command = verify.call_args.args[0]
    assert "PubkeyAuthentication=no" in password_command
    assert "IdentitiesOnly=yes" in verify_command
    assert "IdentityAgent=none" in verify_command
    assert "PreferredAuthentications=publickey" in verify_command
    assert "PasswordAuthentication=no" in verify_command
    assert "KbdInteractiveAuthentication=no" in verify_command
    assert "ControlPath=none" in verify_command
    assert str(keys.with_suffix("")) in verify_command
    assert f"UserKnownHostsFile={tmp_path}/runtime/router/known_hosts" in verify_command
    records = [
        json.loads(line.removeprefix("SSH key setup "))
        for line in capsys.readouterr().err.splitlines()
    ]
    assert records[-1]["stage"] == "complete"
    assert records[-1]["status"] == "success"


def test_failed_key_only_connection_is_not_success(keys, tmp_path):
    with (
        patch.object(
            ssh_setup,
            "run_password_ssh",
            return_value=subprocess.CompletedProcess([], 0, DETAILS, ""),
        ),
        patch.object(
            ssh_setup.subprocess,
            "run",
            return_value=subprocess.CompletedProcess([], 255, "", "Permission denied"),
        ),
        pytest.raises(
            ssh_setup.SshSetupError, match="Key installed.*key-only login failed"
        ),
    ):
        install(keys, tmp_path)


@pytest.mark.parametrize(
    "code,stderr,message",
    [
        (5, "password rejected", "authentication failed"),
        (255, "REMOTE HOST IDENTIFICATION HAS CHANGED!", "does not match"),
        (255, "Host key verification failed.", "does not match"),
        (255, "Connection refused", "connection or remote setup failed"),
        (255, "Permission denied (publickey,password).", "authentication failed"),
        (
            1,
            "chmod: /root/.ssh: Permission denied",
            "connection or remote setup failed",
        ),
    ],
)
def test_connection_failures_do_not_leak_remote_output(
    keys, tmp_path, code, stderr, message, capsys
):
    with (
        patch.object(
            ssh_setup,
            "run_password_ssh",
            return_value=subprocess.CompletedProcess(
                [], code, "", stderr + " one-time-password"
            ),
        ),
        pytest.raises(ssh_setup.SshSetupError, match=message) as error,
    ):
        install(keys, tmp_path)
    assert "one-time-password" not in str(error.value)
    logs = capsys.readouterr().err
    assert "one-time-password" not in logs
    records = [
        json.loads(line.removeprefix("SSH key setup ")) for line in logs.splitlines()
    ]
    completed = next(record for record in records if record.get("exit_code"))
    assert completed["stage"] == "password-login-and-install"
    assert completed["exit_code"] == str(code)
    assert stderr in completed["diagnostic"]
    assert "[password redacted]" in completed["diagnostic"]
    assert records[-1]["status"] == "failed"
    assert records[-1]["host"] == "router"


def test_remote_permission_failure_is_not_reported_as_bad_password(
    keys, tmp_path, capsys
):
    output = "ACME_LOGIN=ok\nACME_STAGE=write-authorized-key\n"
    with (
        patch.object(
            ssh_setup,
            "run_password_ssh",
            return_value=subprocess.CompletedProcess(
                [], 1, output, "chmod: /root/.ssh: Permission denied"
            ),
        ),
        pytest.raises(ssh_setup.SshSetupError, match="SSH login succeeded"),
    ):
        install(keys, tmp_path)
    records = [
        json.loads(line.removeprefix("SSH key setup "))
        for line in capsys.readouterr().err.splitlines()
    ]
    operation = next(record for record in records if "remote_stage" in record)
    assert operation["remote_stage"] == "write-authorized-key"
    assert "chmod" in operation["diagnostic"]


def test_verification_logs_detection_and_ssh_failure(keys, tmp_path, capsys):
    with (
        patch.object(
            ssh_setup,
            "run_password_ssh",
            return_value=subprocess.CompletedProcess([], 0, DETAILS, ""),
        ),
        patch.object(
            ssh_setup.subprocess,
            "run",
            return_value=subprocess.CompletedProcess(
                [], 255, "", "no mutual signature algorithm"
            ),
        ),
        pytest.raises(ssh_setup.SshSetupError),
    ):
        install(keys, tmp_path)
    records = [
        json.loads(line.removeprefix("SSH key setup "))
        for line in capsys.readouterr().err.splitlines()
    ]
    detection = next(record for record in records if "platform" in record)
    assert detection["platform"] == "Linux"
    assert detection["uid"] == "1000"
    assert detection["path"] == "/home/user/.ssh/authorized_keys"
    assert records[-2]["stage"] == "key-only-verification"
    assert records[-2]["diagnostic"] == "no mutual signature algorithm"
    assert records[-1]["status"] == "failed"


def test_log_output_is_bounded_single_line_and_redacts_private_keys(capsys):
    ssh_setup.log_setup_event(
        "router\nforged log",
        "test",
        "secret",
        diagnostic="secret\n\x1b[31m "
        "-----BEGIN OPENSSH PRIVATE KEY-----private-data-----END OPENSSH PRIVATE KEY-----"
        + "x"
        * 5000,
    )
    lines = capsys.readouterr().err.splitlines()
    assert len(lines) == 1
    record = json.loads(lines[0].removeprefix("SSH key setup "))
    assert "secret" not in record["diagnostic"]
    assert "private-data" not in record["diagnostic"]
    assert len(record["diagnostic"]) <= 2000


def test_missing_sshpass_logs_the_underlying_os_error(keys, tmp_path, capsys):
    with (
        patch.object(
            ssh_setup,
            "run_password_ssh",
            side_effect=FileNotFoundError(2, "No such file or directory", "sshpass"),
        ),
        pytest.raises(ssh_setup.SshSetupError, match="could not run"),
    ):
        install(keys, tmp_path)
    records = [
        json.loads(line.removeprefix("SSH key setup "))
        for line in capsys.readouterr().err.splitlines()
    ]
    assert records[-1]["stage"] == "password-login-and-install"
    assert "sshpass" in records[-1]["cause"]
    assert "No such file" in records[-1]["cause"]


def test_password_is_passed_only_through_an_anonymous_pipe():
    def run(command, **kwargs):
        assert command[:2] == ["sshpass", "-d"]
        assert "secret" not in repr(command)
        assert "secret" not in repr(kwargs)
        assert os.read(int(command[2]), 1024) == b"secret\n"
        process = MagicMock()
        process.__enter__.return_value = process
        process.returncode = 0
        process.communicate.return_value = ("", "")
        return process

    with patch.object(ssh_setup.subprocess, "Popen", side_effect=run):
        ssh_setup.run_password_ssh(["ssh", "host", "sh -s"], "secret", "true\n")


def test_timeout_stops_sshpass_and_its_ssh_child():
    process = MagicMock()
    process.__enter__.return_value = process
    process.pid = 123456
    process.communicate.side_effect = [
        subprocess.TimeoutExpired(["sshpass"], 30),
        ("", ""),
    ]
    with (
        patch.object(ssh_setup.subprocess, "Popen", return_value=process),
        patch.object(ssh_setup.os, "killpg") as kill,
        pytest.raises(subprocess.TimeoutExpired),
    ):
        ssh_setup.run_password_ssh(["ssh", "host", "sh -s"], "secret", "true\n")
    kill.assert_called_once_with(process.pid, ssh_setup.signal.SIGKILL)


@pytest.fixture
def api(tmp_path, monkeypatch):
    spec = importlib.util.spec_from_file_location(
        "settings_api", Path(__file__).resolve().parents[1] / "bin/settings-api.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    settings = tmp_path / "settings.yml"
    settings.write_text("hosts:\n  router:\n    url: homologue@192.168.1.1\n")
    monkeypatch.setattr(module, "SETTINGS_PATH", str(settings))
    monkeypatch.setattr(
        module, "find_authenticated_user", lambda header: {"role": header}
    )
    server = module.http.server.HTTPServer(("127.0.0.1", 0), module.SettingsHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield module, f"http://127.0.0.1:{server.server_port}"
    server.shutdown()
    server.server_close()
    thread.join()


def request_api(base, payload, role="admin"):
    request = urllib.request.Request(
        base + "/api/ssh/install-key",
        data=json.dumps(payload).encode(),
        headers={"Authorization": role, "Content-Type": "application/json"},
    )
    try:
        return urllib.request.urlopen(request)
    except urllib.error.HTTPError as error:
        return error


def test_api_requires_admin_and_uses_only_configured_targets(api):
    module, base = api
    with patch.object(
        module, "install_ssh_key", return_value={"status": "ok"}
    ) as installer:
        with request_api(
            base, {"host": "router", "password": "secret"}, role="viewer"
        ) as response:
            assert response.status == 403
        installer.assert_not_called()
        with request_api(
            base,
            {"host": "unconfigured", "password": "secret", "url": "attacker@other"},
        ) as response:
            assert response.status == 400
        installer.assert_not_called()
        with request_api(
            base, {"host": "router", "password": "secret", "url": "attacker@other"}
        ) as response:
            assert response.status == 200
            assert response.headers["Cache-Control"] == "no-store"
        assert installer.call_args.args[:4] == (
            "router",
            "homologue@192.168.1.1",
            "secret",
            "",
        )


@pytest.mark.parametrize("payload", [[], None, {"host": []}, {"host": "missing"}])
def test_api_rejects_malformed_or_unknown_host(api, payload):
    _, base = api
    with request_api(base, payload) as response:
        assert response.status == 400
