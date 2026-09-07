from __future__ import annotations

import argparse
import copy
import getpass
import os
import re
import sys
from pathlib import Path
from typing import Any

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
    display_name = os.environ.get("DISPLAY", "").strip()
    xauthority_name = os.environ.get("XAUTHORITY", "").strip()
    xauthority = Path(xauthority_name) if xauthority_name else None
    if not display_name:
        failures.append("DISPLAY is not configured")
    else:
        local_display = re.fullmatch(r"(?:localhost)?:(\d+)(?:\.\d+)?", display_name)
        if local_display:
            socket = Path(f"/tmp/.X11-unix/X{local_display.group(1)}")
            if not socket.exists():
                failures.append(f"X11 socket does not exist: {socket}")
    if xauthority is None:
        failures.append("XAUTHORITY is not configured")
    elif not xauthority.is_file():
        failures.append(f"Xauthority file does not exist: {xauthority}")
    elif not os.access(xauthority, os.R_OK):
        failures.append(f"Xauthority file is not readable: {xauthority}")
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
    if not failures:
        try:
            from Xlib.display import Display

            display = Display(display_name)
            display.close()
        except Exception as exc:
            failures.append(f"cannot authenticate to X11 display {display_name}: {exc}")
    if failures:
        raise ConfigError("configuration is structurally valid but deployment checks failed:\n- " + "\n- ".join(failures))
    print("Configuration, credentials, paths, and X11 keyboard access are valid.")
    return 0


def command_credentials_set(args: argparse.Namespace, store: ConfigStore) -> int:
    credentials = copy.deepcopy(store.read_credentials())
    credentials["brokers"][args.broker] = _prompt_credentials(args.broker)
    store.write_credentials(credentials)
    print(f"Updated {args.broker} client credentials; affected services will reconnect automatically.")
    print("The broker account itself was not changed.")
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
