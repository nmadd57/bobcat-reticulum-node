"""Tests for make-config.py. The installer's own parser is the judge of every file."""

import base64
import functools
import hashlib
import http.server
import os
import shutil
import subprocess
import sys
import threading
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent
TOOL = HERE / "make-config.py"
INSTALLER = HERE.parent / "installer" / "install-template.sh"

pytestmark = pytest.mark.skipif(shutil.which("bash") is None, reason="bash needed")


# ------------------------------------------------------------------ fake GitHub
BLOB = base64.b64encode(b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20" + bytes(range(32))).decode()
EXPECTED_FP = "SHA256:" + base64.b64encode(hashlib.sha256(base64.b64decode(BLOB)).digest()).decode().rstrip("=")


@pytest.fixture
def github(tmp_path):
    """A local stand-in for github.com that serves /<user>.keys (404 otherwise)."""
    root = tmp_path / "gh"
    root.mkdir()
    (root / "alice.keys").write_text(f"ssh-ed25519 {BLOB} alice@laptop\n")
    (root / "empty.keys").write_text("")

    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=str(root)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{server.server_address[1]}"
    server.shutdown()


def run(*args, stdin=None, cwd=None, env_extra=None, home=None):
    env = dict(os.environ)
    env["HOME"] = str(home) if home else str(cwd or HERE)   # no ~/.ssh keys offered unless a test wants them
    env.pop("BOBCAT_WIFI_PASS", None)
    env.update(env_extra or {})
    return subprocess.run([sys.executable, "-I", str(TOOL), *args], input=stdin, capture_output=True,
                          text=True, cwd=cwd, env=env)


def installer_view(conf, *variables):
    """Load `conf` with the installer's parser and return the named OPT_* variables."""
    body = "; ".join(f'printf "%s\\0" "${{{v}}}"' for v in variables)
    proc = subprocess.run(
        ["bash", "-c", f'BOBCAT_SOURCE_ONLY=1 . "{INSTALLER}" --config "{conf}" 2>/dev/null; {body}'],
        capture_output=True, text=True)
    return proc.stdout.split("\0")[:-1]


def test_scripted_run_writes_a_valid_file(tmp_path):
    out = tmp_path / "c.conf"
    r = run("--wifi-ssid", "HomeNet", "--hostname", "bobcat-01", "--set", "FREQUENCY=868000000",
            "-o", str(out), cwd=tmp_path, env_extra={"BOBCAT_WIFI_PASS": "correct horse battery"})
    assert r.returncode == 0, r.stderr
    assert "settings are valid" in r.stderr
    text = out.read_text()
    assert "WIFI_SSID=HomeNet" in text and "HOSTNAME=bobcat-01" in text and "FREQUENCY=868000000" in text
    assert installer_view(out, "OPT_WIFI_SSID", "OPT_WIFI_PASS", "OPT_FREQ") == \
        ["HomeNet", "correct horse battery", "868000000"]
    if os.name == "posix":
        assert (out.stat().st_mode & 0o777) == 0o600


def test_passphrase_from_a_file_and_never_from_argv(tmp_path):
    pw = tmp_path / "pw"
    pw.write_text("file passphrase 1\n")
    out = tmp_path / "c.conf"
    r = run("--wifi-ssid", "Net", "--wifi-pass-file", str(pw), "-o", str(out), cwd=tmp_path)
    assert r.returncode == 0, r.stderr
    assert installer_view(out, "OPT_WIFI_PASS") == ["file passphrase 1"]
    # there is deliberately no --wifi-pass option
    assert run("--wifi-ssid", "Net", "--wifi-pass", "x", cwd=tmp_path).returncode != 0


def test_open_network_and_hidden(tmp_path):
    out = tmp_path / "c.conf"
    r = run("--wifi-ssid", "Cafe", "--wifi-open", "--wifi-hidden", "-o", str(out), cwd=tmp_path)
    assert r.returncode == 0, r.stderr
    assert installer_view(out, "OPT_WIFI_OPEN", "OPT_WIFI_HIDDEN") == ["1", "1"]


@pytest.mark.parametrize("secret", [
    "  leading and trailing  ", '"quoted"', "it's a passphrase", "'single quoted'", 'p"a\\ss: word#1 ', "$(touch /tmp/x) `id`",
    "ünïcödé ✓ passphrase", "a=b=c=d=e=f", "trailing space ",
])
def test_awkward_values_round_trip_through_the_installer_parser(tmp_path, secret):
    out = tmp_path / "c.conf"
    r = run("--wifi-ssid", "Net", "--no-validate", "-o", str(out), cwd=tmp_path, env_extra={"BOBCAT_WIFI_PASS": secret})
    assert r.returncode == 0, r.stderr
    assert installer_view(out, "OPT_WIFI_PASS") == [secret]


def test_invalid_settings_are_refused_and_nothing_is_written(tmp_path):
    out = tmp_path / "c.conf"
    r = run("--set", "FREQUENCY=12", "-o", str(out), cwd=tmp_path)
    assert r.returncode != 0 and "not valid" in r.stderr and "frequency" in r.stderr
    assert not out.exists()


def test_refuses_to_overwrite_without_force(tmp_path):
    out = tmp_path / "c.conf"
    out.write_text("keep me\n")
    assert run("--hostname", "a", "-o", str(out), cwd=tmp_path).returncode != 0
    assert out.read_text() == "keep me\n"
    assert run("--hostname", "a", "-o", str(out), "--force", cwd=tmp_path).returncode == 0
    assert "HOSTNAME=a" in out.read_text()


def test_stdout_output_and_repeatable_keys(tmp_path):
    r = run("--set", "TCP_CLIENT=hub.example.org:4242", "--set", "TCP_CLIENT=192.0.2.7:4965",
            "--set", "FREQUENCY=915000000", "--set", "FREQUENCY=868000000", "-o", "-", cwd=tmp_path)
    assert r.returncode == 0, r.stderr
    assert r.stdout.count("TCP_CLIENT=") == 2          # repeatable keys accumulate
    assert r.stdout.count("FREQUENCY=") == 1           # others are replaced
    assert "FREQUENCY=868000000" in r.stdout


def test_ssh_key_files_are_added_without_comments(tmp_path):
    keys = tmp_path / "k.pub"
    keys.write_text("# mine\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest one@host\n\nssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7 two@host\n")
    r = run("--ssh-key-file", str(keys), "-o", "-", cwd=tmp_path)
    assert r.returncode == 0, r.stderr
    assert r.stdout.count("SSH_AUTHORIZED_KEY=") == 2 and "# mine" not in r.stdout


def test_nothing_to_write_is_an_error(tmp_path):
    r = run("--non-interactive", cwd=tmp_path)
    assert r.returncode != 0 and "nothing to write" in r.stderr


def test_bad_set_argument(tmp_path):
    assert run("--set", "novalue", cwd=tmp_path).returncode != 0
    assert run("--set", "BAD KEY=1", cwd=tmp_path).returncode != 0


@pytest.mark.skipif(shutil.which("openssl") is None, reason="openssl needed")
def test_root_password_becomes_a_hash_the_installer_accepts(tmp_path):
    answers = "\n".join([
        "n",            # Wi-Fi
        "",             # Ethernet: keep
        "", "",         # hostname, timezone
        "",             # pasted key
        "",             # GitHub users
        "y",            # set a root password
        "s3cret-pw",    # the password (not a tty: read from stdin)
        "n",            # second user
        "y",            # skip first-login prompt
        "n", "n", "n",  # radio change, transport off, IFAC
        "", "n", "",    # mode, TCP hub, server port
        "y", "",        # self-recovery on, default reboot minutes
    ]) + "\n"
    out = tmp_path / "c.conf"
    r = run("-o", str(out), stdin=answers, cwd=tmp_path)
    assert r.returncode == 0, r.stderr + r.stdout
    text = out.read_text()
    assert "ROOT_PASSWORD_HASH=$6$" in text and "s3cret-pw" not in text
    assert "SKIP_FIRSTLOGIN_WIZARD=yes" in text


def test_interactive_questionnaire_end_to_end(tmp_path):
    answers = "\n".join([
        "y",                   # join Wi-Fi
        "Back Yard",           # SSID
        "y",                   # hidden
        "n",                   # open
        "pa ss word 1",        # passphrase
        "static",              # Ethernet mode
        "192.168.1.50/24", "192.168.1.1", "9.9.9.9,1.1.1.1",
        "bobcat-yard",         # hostname
        "Europe/Berlin",       # timezone
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest me@laptop",   # pasted key
        "",                    # GitHub users
        "n",                   # root password
        "n",                   # second user
        "y",                   # skip first-login prompt
        "y",                   # change radio
        "868000000", "250000", "10", "6", "13",
        "y",                   # transport off
        "y", "meshnet", "shared secret",   # IFAC
        "gateway",             # mode
        "y", "hub.example.org:4242", "n",  # TCP hub
        "4242",                # TCP server
        "y", "30",             # self-recovery on, reboot after 30 minutes
    ]) + "\n"
    out = tmp_path / "c.conf"
    r = run("-o", str(out), stdin=answers, cwd=tmp_path)
    assert r.returncode == 0, r.stderr + r.stdout
    got = installer_view(out, "OPT_WIFI_SSID", "OPT_WIFI_PASS", "OPT_WIFI_HIDDEN", "OPT_ETH_MODE", "OPT_ETH_ADDR",
                         "OPT_ETH_GW", "OPT_ETH_DNS", "OPT_HOSTNAME", "OPT_TIMEZONE", "OPT_FREQ", "OPT_BW",
                         "OPT_SF", "OPT_CR", "OPT_TXP", "OPT_TRANSPORT", "OPT_IFAC_NET", "OPT_IFAC_PASS",
                         "OPT_IFMODE", "OPT_TCP_PORT", "OPT_SKIP_WIZARD", "OPT_RESILIENCE", "OPT_NW_REBOOT")
    assert got == ["Back Yard", "pa ss word 1", "1", "static", "192.168.1.50/24", "192.168.1.1",
                   "9.9.9.9,1.1.1.1", "bobcat-yard", "Europe/Berlin", "868000000", "250000", "10", "6", "13",
                   "0", "meshnet", "shared secret", "gateway", "4242", "1", "1", "30"]
    assert "TCP_CLIENT=hub.example.org:4242" in out.read_text()
    assert "ssh-ed25519" in out.read_text()


def test_questionnaire_reprompts_on_a_bad_answer(tmp_path):
    answers = "\n".join(["y", "Net", "n", "n", "short", "longenough1",   # passphrase: too short, then ok
                         "keep", "", "", "", "", "n", "n", "y", "n", "n", "n", "", "n", "", "y", ""]) + "\n"
    r = run("-o", str(tmp_path / "c.conf"), stdin=answers, cwd=tmp_path)
    assert r.returncode == 0, r.stderr + r.stdout
    assert "8 to 63 characters" in r.stdout


def test_github_user_is_verified_and_written(tmp_path, github):
    out = tmp_path / "c.conf"
    r = run("--ssh-github-user", "alice", "-o", str(out), cwd=tmp_path, env_extra={"BOBCAT_GITHUB_URL": github})
    assert r.returncode == 0, r.stderr
    assert "SSH_GITHUB_USER=alice" in out.read_text()
    assert EXPECTED_FP in r.stderr            # the fingerprint is shown so you can recognise your key
    assert "ssh-ed25519" in r.stderr
    assert installer_view(out, "OPT_GH_USERS[*]") == ["alice"]


def test_unknown_github_user_is_refused(tmp_path, github):
    out = tmp_path / "c.conf"
    r = run("--ssh-github-user", "nosuchuser", "-o", str(out), cwd=tmp_path, env_extra={"BOBCAT_GITHUB_URL": github})
    assert r.returncode != 0 and "no user 'nosuchuser'" in r.stderr
    assert not out.exists()


def test_github_user_without_keys_is_refused(tmp_path, github):
    r = run("--ssh-github-user", "empty", "-o", "-", cwd=tmp_path, env_extra={"BOBCAT_GITHUB_URL": github})
    assert r.returncode != 0 and "no SSH public keys" in r.stderr


def test_unreachable_github_warns_but_still_writes(tmp_path):
    out = tmp_path / "c.conf"
    r = run("--ssh-github-user", "alice", "-o", str(out), cwd=tmp_path,
            env_extra={"BOBCAT_GITHUB_URL": "http://127.0.0.1:1"})
    assert r.returncode == 0, r.stderr
    assert "could not reach GitHub" in r.stderr and "SSH_GITHUB_USER=alice" in out.read_text()


def test_no_github_check_skips_the_lookup(tmp_path):
    r = run("--ssh-github-user", "whoever", "--no-github-check", "-o", "-", cwd=tmp_path,
            env_extra={"BOBCAT_GITHUB_URL": "http://127.0.0.1:1"})
    assert r.returncode == 0 and "SSH_GITHUB_USER=whoever" in r.stdout
    assert "could not reach" not in r.stderr


def test_bad_github_names_are_rejected_before_any_lookup(tmp_path):
    for bad in ("-x", "x-", "a--b", "../etc", "has space", "a" * 40):
        r = run(f"--ssh-github-user={bad}", "-o", "-", cwd=tmp_path, env_extra={"BOBCAT_GITHUB_URL": "http://127.0.0.1:1"})
        assert r.returncode != 0 and "GitHub username" in r.stderr, bad


def test_several_github_users_and_other_keys_together(tmp_path, github):
    keys = tmp_path / "k.pub"
    keys.write_text("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAImine mine@host\n")
    r = run("--ssh-github-user", "alice", "--ssh-github-user", "alice", "--ssh-key-file", str(keys), "-o", "-",
            cwd=tmp_path, env_extra={"BOBCAT_GITHUB_URL": github})
    assert r.returncode == 0, r.stderr
    assert r.stdout.count("SSH_GITHUB_USER=alice") == 2 and "SSH_AUTHORIZED_KEY=ssh-ed25519" in r.stdout


def test_questionnaire_asks_for_github_users_and_retries_a_wrong_one(tmp_path, github):
    answers = "\n".join([
        "n",                          # Wi-Fi
        "",                           # Ethernet keep
        "", "",                       # hostname, timezone
        "",                           # pasted key
        "nosuchuser",                 # GitHub: does not exist -> asked again
        "alice",                      # GitHub: fine
        "n", "n", "y",                # root password no, second user no, skip first-login yes
        "n", "n", "n", "", "n", "",   # radio, transport, IFAC, mode, hub, server
        "y", "",                      # self-recovery on, default minutes
    ]) + "\n"
    out = tmp_path / "c.conf"
    r = run("-o", str(out), stdin=answers, cwd=tmp_path, env_extra={"BOBCAT_GITHUB_URL": github})
    assert r.returncode == 0, r.stderr + r.stdout
    assert "no user 'nosuchuser'" in r.stdout and "Please try again" in r.stdout
    assert EXPECTED_FP in r.stdout
    assert out.read_text().count("SSH_GITHUB_USER=alice") == 1 and "nosuchuser" not in out.read_text()


def test_questionnaire_can_turn_self_recovery_off(tmp_path):
    answers = "\n".join(["n", "", "", "", "", "", "n", "n", "y", "n", "n", "n", "", "n", "", "n"]) + "\n"
    out = tmp_path / "c.conf"
    r = run("-o", str(out), stdin=answers, cwd=tmp_path)
    assert r.returncode == 0, r.stderr + r.stdout
    assert "RESILIENCE=no" in out.read_text()
    assert installer_view(out, "OPT_RESILIENCE") == ["0"]


def test_self_recovery_settings_are_validated_by_the_installer(tmp_path):
    r = run("--set", "NETWATCH_REBOOT_MINUTES=2", "-o", "-", cwd=tmp_path)
    assert r.returncode != 0 and "reboot minutes" in r.stderr
    ok = run("--set", "NETWATCH_REBOOT_MINUTES=45", "--set", "LOG_KEEP_DAYS=7", "--set", "LOG_MAX_MB=200", "-o", "-", cwd=tmp_path)
    assert ok.returncode == 0, ok.stderr
    assert "NETWATCH_REBOOT_MINUTES=45" in ok.stdout


def test_second_user_with_password_sudo_and_key(tmp_path):
    key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl you@laptop"
    answers = "\n".join([
        "n",            # Wi-Fi
        "",             # Ethernet: keep
        "", "",         # hostname, timezone
        key,            # pasted key (root)
        "",             # GitHub users
        "n",            # root password
        "y",            # second user
        "alice",        # name
        "y", "pw-alice",   # a password for alice (read from stdin here)
        "y",            # sudo
        key, "",        # a key for alice, then done
        "y",            # skip first-login prompt
        "n", "n", "n",  # radio change, transport off, IFAC
        "", "n", "",    # mode, TCP hub, server port
        "y", "",        # self-recovery on, default reboot minutes
    ]) + "\n"
    out = tmp_path / "c.conf"
    r = run("-o", str(out), stdin=answers, cwd=tmp_path)
    text = out.read_text()
    assert "USER_NAME=alice" in text and "USER_PASSWORD_HASH=$6$" in text and "USER_SUDO=yes" in text, r.stdout + r.stderr + text
    assert text.count("USER_SSH_KEY=") == 1 and "pw-alice" not in text
