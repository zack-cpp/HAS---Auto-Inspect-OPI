from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import textwrap

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]
SETUP_SCRIPT = REPO_ROOT / "setup" / "setup-kiosk.sh"


pytestmark = pytest.mark.skipif(
    os.name != "posix" or shutil.which("bash") is None,
    reason="generated kiosk launcher requires a Linux Bash environment",
)


def _extract_kiosk_launcher() -> str:
    lines = SETUP_SCRIPT.read_text(encoding="utf-8").splitlines()
    start = lines.index('cat >"$KIOSK_SCRIPT" <<\'KIOSK_EOF\'') + 1
    end = lines.index("KIOSK_EOF", start)
    return "\n".join(lines[start:end]) + "\n"


def test_installer_adds_narrow_counterctl_kiosk_restart_bridge():
    installer = SETUP_SCRIPT.read_text(encoding="utf-8")

    assert 'readonly KIOSK_RESTART_REQUEST="$URL_DIR/restart-request"' in installer
    assert "PathExists=$KIOSK_RESTART_REQUEST" in installer
    assert "ExecStart=/bin/rm -f $KIOSK_RESTART_REQUEST" in installer
    assert "ExecStart=/usr/bin/systemctl --no-block restart getty@tty1.service" in installer
    assert "systemctl enable --now counter-inspect-kiosk-restart.path" in installer
    assert 'touch "$KIOSK_RESTART_READY"' in installer


def _write_executable(path: Path, body: str) -> None:
    path.write_text(textwrap.dedent(body).lstrip(), encoding="utf-8")
    path.chmod(0o755)


def _materialize_launcher(tmp_path: Path, profile_dir: Path, url_file: Path) -> Path:
    launcher = _extract_kiosk_launcher()
    launcher = launcher.replace(
        'readonly URL_FILE="/etc/kiosk/url"',
        f'readonly URL_FILE="{url_file}"',
    )
    launcher = launcher.replace(
        'readonly CHROMIUM_PROFILE_DIR="/root/.config/chromium"',
        f'readonly CHROMIUM_PROFILE_DIR="{profile_dir}"',
    )
    launcher = launcher.replace(
        'readonly DISPLAY_POLL_SECONDS="2"',
        'readonly DISPLAY_POLL_SECONDS="0.01"',
    )
    launcher = launcher.replace(
        'install -d -o root -g root -m 0700 "$CHROMIUM_PROFILE_DIR"',
        'install -d -m 0700 "$CHROMIUM_PROFILE_DIR"',
    )
    launcher = launcher.replace("sleep 2", "sleep 0.08")

    launcher_path = tmp_path / "kiosk.sh"
    launcher_path.write_text(launcher, encoding="utf-8")
    launcher_path.chmod(0o755)
    return launcher_path


def _create_fake_desktop_commands(fake_bin: Path) -> None:
    _write_executable(fake_bin / "openbox-session", "#!/bin/sh\nexit 0\n")
    _write_executable(fake_bin / "xset", "#!/bin/sh\nexit 0\n")


def test_launcher_preserves_profile_and_recovers_hotplug(tmp_path: Path) -> None:
    profile_dir = tmp_path / "profile"
    profile_dir.mkdir()
    preserved = {
        "Cookies": b"cookie-database",
        "Login Data": b"saved-password-database",
        "Preferences": b'{"session": "persistent"}',
    }
    for name, contents in preserved.items():
        (profile_dir / name).write_bytes(contents)
    for name in ("SingletonLock", "SingletonSocket", "SingletonCookie"):
        (profile_dir / name).write_text("stale", encoding="utf-8")

    url_file = tmp_path / "url"
    url_file.write_text("http://kiosk.example\n", encoding="utf-8")
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    _create_fake_desktop_commands(fake_bin)

    xrandr_count = tmp_path / "xrandr-count"
    xrandr_log = tmp_path / "xrandr-log"
    chromium_log = tmp_path / "chromium-args"
    _write_executable(
        fake_bin / "xrandr",
        f"""
        #!/bin/sh
        if [ "${{1:-}}" = "--query" ]; then
            count=0
            [ ! -f "{xrandr_count}" ] || count=$(cat "{xrandr_count}")
            count=$((count + 1))
            printf '%s' "$count" > "{xrandr_count}"
            if [ "$count" -le 5 ]; then
                printf '%s\n' 'HDMI-1 disconnected'
            else
                printf '%s\n' 'HDMI-1 connected 1920x1080+0+0' '   1920x1080 60.00*+'
            fi
            exit 0
        fi
        printf '%s\n' "$*" >> "{xrandr_log}"
        """,
    )
    _write_executable(
        fake_bin / "chromium",
        f"""
        #!/bin/sh
        printf '%s\n' "$@" > "{chromium_log}"
        sleep 0.12
        """,
    )

    launcher = _materialize_launcher(tmp_path, profile_dir, url_file)
    env = os.environ.copy()
    env["PATH"] = f"{fake_bin}:/usr/bin:/bin"
    result = subprocess.run(
        ["bash", str(launcher)],
        env=env,
        capture_output=True,
        text=True,
        timeout=5,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    for name, contents in preserved.items():
        assert (profile_dir / name).read_bytes() == contents
    for name in ("SingletonLock", "SingletonSocket", "SingletonCookie"):
        assert not (profile_dir / name).exists()

    chromium_args = chromium_log.read_text(encoding="utf-8")
    assert f"--user-data-dir={profile_dir}" in chromium_args
    assert "http://kiosk.example" in chromium_args

    display_args = xrandr_log.read_text(encoding="utf-8")
    assert "--output HDMI-1" in display_args
    assert "--preferred" in display_args
    assert "--primary" in display_args
    assert "--pos 0x0" in display_args
    assert "--rotate normal" in display_args
    assert "--scale 1x1" in display_args


def test_launcher_does_not_unlock_an_active_profile(tmp_path: Path) -> None:
    profile_dir = tmp_path / "profile"
    profile_dir.mkdir()
    lock_file = profile_dir / "SingletonLock"
    lock_file.write_text("active", encoding="utf-8")
    url_file = tmp_path / "url"
    url_file.write_text("http://kiosk.example\n", encoding="utf-8")

    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    _create_fake_desktop_commands(fake_bin)
    _write_executable(
        fake_bin / "xrandr",
        """
        #!/bin/sh
        [ "${1:-}" != "--query" ] || printf '%s\n' 'HDMI-1 disconnected'
        """,
    )
    _write_executable(
        fake_bin / "chromium",
        """
        #!/bin/sh
        sleep 30
        """,
    )

    launcher = _materialize_launcher(tmp_path, profile_dir, url_file)
    env = os.environ.copy()
    env["PATH"] = f"{fake_bin}:/usr/bin:/bin"
    active = subprocess.Popen(
        [str(fake_bin / "chromium"), f"--user-data-dir={profile_dir}"],
        env=env,
    )
    try:
        result = subprocess.run(
            ["bash", str(launcher)],
            env=env,
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    finally:
        active.terminate()
        active.wait(timeout=5)

    assert result.returncode != 0
    assert "profile is already in use" in result.stderr
    assert lock_file.read_text(encoding="utf-8") == "active"
