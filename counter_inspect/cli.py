from __future__ import annotations

import argparse
import copy
import getpass
import os
import sys
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

import yaml

from .config import (
    ConfigError,
    ConfigStore,
    atomic_write,
    clone_default_credentials,
    clone_default_runtime,
    generate_key,
    validate_runtime,
)


DATA_UID = 10001
DATA_GID = 10001
KIOSK_DIR = Path(os.environ.get("COUNTER_KIOSK_DIR", "/host/kiosk"))
KIOSK_URL_PATH = KIOSK_DIR / "url"
KIOSK_RESTART_REQUEST_PATH = KIOSK_DIR / "restart-request"
KIOSK_RESTART_READY_PATH = KIOSK_DIR / "restart-via-systemd"


def _ensure_directory(path: Path, mode: int = 0o750) -> None:
    path.mkdir(parents=True, exist_ok=True)
    try:
        os.chown(path, DATA_UID, DATA_GID)
        os.chmod(path, mode)
    except (AttributeError, OSError):
        pass


def _prompt_credentials(name: str) -> dict[str, str]:
    username = input(f"{name.capitalize()} MQTT username (blank for anonymous): ").strip()
    password = getpass.getpass(f"{name.capitalize()} MQTT password (blank for none): ")
    confirmation = getpass.getpass("Confirm password: ")
    if password != confirmation:
        raise ConfigError("password confirmation does not match")
    return {"username": username, "password": password}


def command_init(args: argparse.Namespace, store: ConfigStore) -> int:
    existing = [path for path in (store.config_path, store.credentials_path, store.key_path) if path.exists()]
    if existing and not args.force:
        raise ConfigError(
            "initialization refused because files already exist; use --force to replace all configuration"
        )

    runtime = clone_default_runtime()
    if args.device_id:
        runtime["device_id"] = args.device_id
    validate_runtime(runtime)

    credentials = clone_default_credentials()
    credentials["brokers"]["local"] = _prompt_credentials("local")
    credentials["brokers"]["remote"] = _prompt_credentials("remote")

    _ensure_directory(store.config_path.parent)
    _ensure_directory(store.key_path.parent)
    key = generate_key()
    atomic_write(store.key_path, key, mode=0o640, uid=DATA_UID, gid=DATA_GID)
    store.write_runtime(runtime)
    store.write_credentials(credentials)

    _ensure_directory(Path("/data/logs"))
    _ensure_directory(Path("/data/queue"))
    # The unprivileged static HTTP container must be able to traverse and read
    # this directory. Firmware files themselves are written with mode 0644.
    _ensure_directory(Path("/data/updates"), mode=0o755)

    print(f"Initialized runtime configuration at {store.config_path}")
    print("Credentials were encrypted; running services will reload future edits automatically.")
    if runtime["device_id"] == "CHANGE-ME":
        print("Warning: set device_id before starting the services.", file=sys.stderr)
    if args.scanner_device:
        print(
            "Warning: --scanner-device is deprecated and ignored; scanner input is captured from X11.",
            file=sys.stderr,
        )
    return 0


def command_config_show(_args: argparse.Namespace, store: ConfigStore) -> int:
    runtime = copy.deepcopy(store.read_runtime())
    credentials = store.read_credentials()
    runtime["credentials"] = {
        broker: {
            "username": values["username"],
            "password": "<redacted>" if values["password"] else "",
        }
        for broker, values in credentials["brokers"].items()
    }
    print(yaml.safe_dump(runtime, sort_keys=False), end="")
    return 0


def _parse_scalar(value: str) -> Any:
    try:
        parsed = yaml.safe_load(value)
    except yaml.YAMLError as exc:
        raise ConfigError(f"value is invalid YAML: {exc}") from exc
    if isinstance(parsed, (dict, list)):
        raise ConfigError("config set accepts only a scalar value")
    return parsed


def _set_existing_path(document: dict[str, Any], dotted_key: str, value: Any) -> None:
    if not dotted_key or dotted_key.startswith("credentials"):
        raise ConfigError("use 'credentials set' for broker credentials")
    parts = dotted_key.split(".")
    cursor: Any = document
    for part in parts[:-1]:
        if not isinstance(cursor, dict) or part not in cursor:
            raise ConfigError(f"unknown configuration key: {dotted_key}")
        cursor = cursor[part]
    leaf = parts[-1]
    if not isinstance(cursor, dict) or leaf not in cursor or isinstance(cursor[leaf], (dict, list)):
        raise ConfigError(f"unknown or non-scalar configuration key: {dotted_key}")
    cursor[leaf] = value


def command_config_set(args: argparse.Namespace, store: ConfigStore) -> int:
    runtime = copy.deepcopy(store.read_runtime())
    _set_existing_path(runtime, args.key, _parse_scalar(args.value))
    store.write_runtime(runtime)
    print(f"Updated {args.key}; services will apply the change automatically.")
    return 0


def command_config_validate(_args: argparse.Namespace, store: ConfigStore) -> int:
    settings = store.load()
    failures: list[str] = []
    for name, path in (
        ("queue directory", settings.storage.queue_dir),
        ("log directory", settings.storage.log_dir),
        ("updates directory", settings.ota.updates_dir),
    ):
        if not path.exists():
            failures.append(f"{name} does not exist: {path}")
        elif not os.access(path, os.W_OK):
            failures.append(f"{name} is not writable: {path}")
    if settings.device_id == "CHANGE-ME":
        failures.append("device_id still has its placeholder value")
    if failures:
        raise ConfigError("configuration is structurally valid but deployment checks failed:\n- " + "\n- ".join(failures))
    print("Configuration, credentials, and writable data paths are valid.")
    return 0


def command_credentials_set(args: argparse.Namespace, store: ConfigStore) -> int:
    credentials = copy.deepcopy(store.read_credentials())
    credentials["brokers"][args.broker] = _prompt_credentials(args.broker)
    store.write_credentials(credentials)
    print(f"Updated {args.broker} client credentials; affected services will reconnect automatically.")
    print("The broker account itself was not changed.")
    return 0


def _validate_kiosk_url(value: str) -> str:
    url = value.strip()
    if not url:
        raise ConfigError("kiosk URL cannot be empty")
    if any(character.isspace() or ord(character) < 32 for character in url):
        raise ConfigError("kiosk URL cannot contain whitespace or control characters")

    try:
        parsed = urlsplit(url)
        hostname = parsed.hostname
        # Accessing port makes urllib validate malformed or out-of-range ports.
        parsed.port
    except ValueError as exc:
        raise ConfigError(f"kiosk URL is invalid: {exc}") from exc
    if parsed.scheme not in {"http", "https"} or not parsed.netloc or hostname is None:
        raise ConfigError("kiosk URL must be an absolute http:// or https:// URL")
    return url


def _read_kiosk_url() -> str:
    try:
        value = KIOSK_URL_PATH.read_text(encoding="utf-8")
    except FileNotFoundError as exc:
        raise ConfigError(
            f"kiosk URL file not found: {KIOSK_URL_PATH}; run setup/setup-kiosk.sh on the host first"
        ) from exc
    except OSError as exc:
        raise ConfigError(f"cannot read kiosk URL file {KIOSK_URL_PATH}: {exc}") from exc
    return _validate_kiosk_url(value)


def _request_kiosk_restart() -> None:
    if not KIOSK_DIR.is_dir():
        raise ConfigError(
            f"kiosk configuration directory not found: {KIOSK_DIR}; run setup/setup-kiosk.sh on the host first"
        )
    if not KIOSK_RESTART_READY_PATH.is_file():
        raise ConfigError(
            "host kiosk restart support is not installed; rerun setup/setup-kiosk.sh with the current URL"
        )
    try:
        # Replacing an old, unconsumed request makes a subsequent request
        # observable to the host systemd path unit as a fresh file creation.
        KIOSK_RESTART_REQUEST_PATH.unlink(missing_ok=True)
        atomic_write(KIOSK_RESTART_REQUEST_PATH, b"restart\n", mode=0o644)
    except OSError as exc:
        raise ConfigError(f"cannot request kiosk restart: {exc}") from exc


def command_kiosk_show(_args: argparse.Namespace, _store: ConfigStore) -> int:
    print(_read_kiosk_url())
    return 0


def command_kiosk_set(args: argparse.Namespace, _store: ConfigStore) -> int:
    url = _validate_kiosk_url(args.url)
    if not KIOSK_DIR.is_dir():
        raise ConfigError(
            f"kiosk configuration directory not found: {KIOSK_DIR}; run setup/setup-kiosk.sh on the host first"
        )
    try:
        atomic_write(KIOSK_URL_PATH, f"{url}\n".encode("utf-8"), mode=0o644)
    except OSError as exc:
        raise ConfigError(f"cannot update kiosk URL file {KIOSK_URL_PATH}: {exc}") from exc

    print(f"Updated kiosk URL to {url}.")
    if args.restart:
        _request_kiosk_restart()
        print("Requested a kiosk restart; Docker application services remain running.")
    else:
        print("Run 'counterctl kiosk restart' to apply it to the current Chromium session.")
    return 0


def command_kiosk_restart(_args: argparse.Namespace, _store: ConfigStore) -> int:
    # Refuse to restart a kiosk whose URL is absent or malformed.
    _read_kiosk_url()
    _request_kiosk_restart()
    print("Requested a kiosk restart; Docker application services remain running.")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="counterctl", description="Manage Counter Inspect configuration")
    subcommands = parser.add_subparsers(dest="command", required=True)

    init_parser = subcommands.add_parser("init", help="initialize configuration and encrypted credentials")
    init_parser.add_argument("--force", action="store_true", help="replace existing configuration and key")
    init_parser.add_argument("--device-id", help="initial shared device ID")
    init_parser.add_argument(
        "--scanner-device",
        help="deprecated compatibility option; X11 capture does not use a scanner device path",
    )
    init_parser.set_defaults(handler=command_init)

    config_parser = subcommands.add_parser("config", help="view and edit runtime configuration")
    config_commands = config_parser.add_subparsers(dest="config_command", required=True)
    show_parser = config_commands.add_parser("show", help="show configuration with redacted passwords")
    show_parser.set_defaults(handler=command_config_show)
    set_parser = config_commands.add_parser("set", help="set an existing scalar configuration key")
    set_parser.add_argument("key")
    set_parser.add_argument("value")
    set_parser.set_defaults(handler=command_config_set)
    validate_parser = config_commands.add_parser("validate", help="validate configuration and deployment paths")
    validate_parser.set_defaults(handler=command_config_validate)

    credentials_parser = subcommands.add_parser("credentials", help="edit encrypted MQTT credentials")
    credential_commands = credentials_parser.add_subparsers(dest="credentials_command", required=True)
    credential_set = credential_commands.add_parser("set", help="set client credentials for a broker")
    credential_set.add_argument("broker", choices=("local", "remote"))
    credential_set.set_defaults(handler=command_credentials_set)

    kiosk_parser = subcommands.add_parser("kiosk", help="view, update, and restart the host kiosk")
    kiosk_commands = kiosk_parser.add_subparsers(dest="kiosk_command", required=True)
    kiosk_show = kiosk_commands.add_parser("show", help="show the current kiosk URL")
    kiosk_show.set_defaults(handler=command_kiosk_show)
    kiosk_set = kiosk_commands.add_parser("set", help="atomically update the kiosk URL")
    kiosk_set.add_argument("url", help="absolute http:// or https:// kiosk URL")
    kiosk_set.add_argument(
        "--restart",
        action="store_true",
        help="request a kiosk restart immediately after updating the URL",
    )
    kiosk_set.set_defaults(handler=command_kiosk_set)
    kiosk_restart = kiosk_commands.add_parser("restart", help="restart X11 and Chromium through the host")
    kiosk_restart.set_defaults(handler=command_kiosk_restart)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.handler(args, ConfigStore())
    except ConfigError as exc:
        print(f"counterctl: {exc}", file=sys.stderr)
        return 2
    except (EOFError, KeyboardInterrupt):
        print("\ncounterctl: cancelled", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
