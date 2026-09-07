from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import tempfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, Callable
from urllib.parse import urlparse

import yaml
from cryptography.hazmat.primitives.ciphers.aead import AESGCM


CONFIG_VERSION = 1
SECRET_AAD = b"counter-inspect-credentials-v1"
DEFAULT_CONFIG_PATH = Path(os.environ.get("COUNTER_CONFIG_PATH", "/config/runtime.yaml"))
DEFAULT_CREDENTIALS_PATH = Path(
    os.environ.get("COUNTER_CREDENTIALS_PATH", "/config/credentials.enc")
)
DEFAULT_KEY_PATH = Path(os.environ.get("COUNTER_KEY_PATH", "/key/master.key"))


class ConfigError(ValueError):
    """Raised when runtime configuration or credentials are invalid."""


@dataclass(frozen=True)
class BrokerCredentials:
    username: str
    password: str


@dataclass(frozen=True)
class BrokerSettings:
    host: str
    port: int
    credentials: BrokerCredentials


@dataclass(frozen=True)
class OtaSettings:
    source_base_url: str
    download_timeout_seconds: float
    updates_dir: Path


@dataclass(frozen=True)
class ScannerSettings:
    char_timeout_seconds: float


@dataclass(frozen=True)
class StorageSettings:
    queue_dir: Path
    log_dir: Path


@dataclass(frozen=True)
class RuntimeSettings:
    log_level: str
    reconnect_min_seconds: int
    reconnect_max_seconds: int
    config_poll_seconds: float


@dataclass(frozen=True)
class Settings:
    device_id: str
    local_broker: BrokerSettings
    remote_broker: BrokerSettings
    ota: OtaSettings
    scanner: ScannerSettings
    storage: StorageSettings
    runtime: RuntimeSettings


DEFAULT_RUNTIME: dict[str, Any] = {
    "version": CONFIG_VERSION,
    "device_id": "CHANGE-ME",
    "brokers": {
        "local": {"host": "host.docker.internal", "port": 1883},
        "remote": {"host": "andon-dev.web.id", "port": 1883},
    },
    "ota": {
        "source_base_url": "http://andon-dev.web.id:9000",
        "download_timeout_seconds": 30,
        "updates_dir": "/data/updates",
    },
    "scanner": {
        "char_timeout_seconds": 0.2,
    },
    "storage": {"queue_dir": "/data/queue", "log_dir": "/data/logs"},
    "runtime": {
        "log_level": "INFO",
        "reconnect_min_seconds": 2,
        "reconnect_max_seconds": 30,
        "config_poll_seconds": 1.0,
    },
}

DEFAULT_CREDENTIALS: dict[str, Any] = {
    "version": CONFIG_VERSION,
    "brokers": {
        "local": {"username": "", "password": ""},
        "remote": {"username": "", "password": ""},
    },
}


def _require_mapping(value: Any, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ConfigError(f"{name} must be a mapping")
    return value


def _require_string(value: Any, name: str, *, allow_empty: bool = False) -> str:
    if not isinstance(value, str) or (not allow_empty and not value.strip()):
        raise ConfigError(f"{name} must be a non-empty string")
    return value.strip() if not allow_empty else value


def _require_int(value: Any, name: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ConfigError(f"{name} must be an integer")
    if not minimum <= value <= maximum:
        raise ConfigError(f"{name} must be between {minimum} and {maximum}")
    return value


def _require_number(value: Any, name: str, minimum: float, maximum: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ConfigError(f"{name} must be a number")
    result = float(value)
    if not minimum <= result <= maximum:
        raise ConfigError(f"{name} must be between {minimum} and {maximum}")
    return result


def _validate_keys(mapping: dict[str, Any], expected: set[str], name: str) -> None:
    unknown = set(mapping) - expected
    missing = expected - set(mapping)
    if unknown:
        raise ConfigError(f"{name} contains unknown keys: {', '.join(sorted(unknown))}")
    if missing:
        raise ConfigError(f"{name} is missing keys: {', '.join(sorted(missing))}")


def _validate_keys_with_optional(
    mapping: dict[str, Any], required: set[str], optional: set[str], name: str
) -> None:
    unknown = set(mapping) - required - optional
    missing = required - set(mapping)
    if unknown:
        raise ConfigError(f"{name} contains unknown keys: {', '.join(sorted(unknown))}")
    if missing:
        raise ConfigError(f"{name} is missing keys: {', '.join(sorted(missing))}")


def _is_absolute_path(value: str) -> bool:
    """Accept Linux deployment paths while allowing native paths in local tests/tools."""
    return PurePosixPath(value).is_absolute() or Path(value).is_absolute()


def validate_runtime(document: Any) -> dict[str, Any]:
    root = _require_mapping(document, "configuration")
    _validate_keys(
        root,
        {"version", "device_id", "brokers", "ota", "scanner", "storage", "runtime"},
        "configuration",
    )
    if root["version"] != CONFIG_VERSION:
        raise ConfigError(f"unsupported configuration version: {root['version']!r}")

    device_id = _require_string(root["device_id"], "device_id")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}", device_id):
        raise ConfigError("device_id must contain only letters, digits, dot, underscore, or dash")

    brokers = _require_mapping(root["brokers"], "brokers")
    _validate_keys(brokers, {"local", "remote"}, "brokers")
    for broker_name in ("local", "remote"):
        broker = _require_mapping(brokers[broker_name], f"brokers.{broker_name}")
        _validate_keys(broker, {"host", "port"}, f"brokers.{broker_name}")
        _require_string(broker["host"], f"brokers.{broker_name}.host")
        _require_int(broker["port"], f"brokers.{broker_name}.port", 1, 65535)

    ota = _require_mapping(root["ota"], "ota")
    _validate_keys(ota, {"source_base_url", "download_timeout_seconds", "updates_dir"}, "ota")
    source_url = _require_string(ota["source_base_url"], "ota.source_base_url")
    parsed = urlparse(source_url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ConfigError("ota.source_base_url must be an absolute HTTP or HTTPS URL")
    if parsed.query or parsed.fragment:
        raise ConfigError("ota.source_base_url must not contain a query or fragment")
    _require_number(ota["download_timeout_seconds"], "ota.download_timeout_seconds", 1, 600)
    if not _is_absolute_path(_require_string(ota["updates_dir"], "ota.updates_dir")):
        raise ConfigError("ota.updates_dir must be an absolute path")

    scanner = _require_mapping(root["scanner"], "scanner")
    # input_device was used by the evdev backend. Accept it temporarily so
    # existing installations remain valid, but it is intentionally ignored.
    _validate_keys_with_optional(scanner, {"char_timeout_seconds"}, {"input_device"}, "scanner")
    if "input_device" in scanner:
        _require_string(scanner["input_device"], "scanner.input_device")
    _require_number(scanner["char_timeout_seconds"], "scanner.char_timeout_seconds", 0.01, 10)

    storage = _require_mapping(root["storage"], "storage")
    _validate_keys(storage, {"queue_dir", "log_dir"}, "storage")
    for key in ("queue_dir", "log_dir"):
        if not _is_absolute_path(_require_string(storage[key], f"storage.{key}")):
            raise ConfigError(f"storage.{key} must be an absolute path")

    runtime = _require_mapping(root["runtime"], "runtime")
    _validate_keys(
        runtime,
        {"log_level", "reconnect_min_seconds", "reconnect_max_seconds", "config_poll_seconds"},
        "runtime",
    )
    level = _require_string(runtime["log_level"], "runtime.log_level").upper()
    if level not in {"DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"}:
        raise ConfigError("runtime.log_level is invalid")
    minimum = _require_int(runtime["reconnect_min_seconds"], "runtime.reconnect_min_seconds", 1, 300)
    maximum = _require_int(runtime["reconnect_max_seconds"], "runtime.reconnect_max_seconds", 1, 3600)
    if maximum < minimum:
        raise ConfigError("runtime.reconnect_max_seconds must be >= reconnect_min_seconds")
    _require_number(runtime["config_poll_seconds"], "runtime.config_poll_seconds", 0.2, 60)
    return root


def validate_credentials(document: Any) -> dict[str, Any]:
    root = _require_mapping(document, "credentials")
    _validate_keys(root, {"version", "brokers"}, "credentials")
    if root["version"] != CONFIG_VERSION:
        raise ConfigError(f"unsupported credentials version: {root['version']!r}")
    brokers = _require_mapping(root["brokers"], "credentials.brokers")
    _validate_keys(brokers, {"local", "remote"}, "credentials.brokers")
    for broker_name in ("local", "remote"):
        broker = _require_mapping(brokers[broker_name], f"credentials.brokers.{broker_name}")
        _validate_keys(broker, {"username", "password"}, f"credentials.brokers.{broker_name}")
        _require_string(broker["username"], f"credentials.brokers.{broker_name}.username", allow_empty=True)
        _require_string(broker["password"], f"credentials.brokers.{broker_name}.password", allow_empty=True)
    return root


def parse_settings(runtime: dict[str, Any], credentials: dict[str, Any]) -> Settings:
    validate_runtime(runtime)
    validate_credentials(credentials)

    def broker(name: str) -> BrokerSettings:
        endpoint = runtime["brokers"][name]
        secret = credentials["brokers"][name]
        return BrokerSettings(
            host=endpoint["host"],
            port=endpoint["port"],
            credentials=BrokerCredentials(secret["username"], secret["password"]),
        )

    return Settings(
        device_id=runtime["device_id"],
        local_broker=broker("local"),
        remote_broker=broker("remote"),
        ota=OtaSettings(
            source_base_url=runtime["ota"]["source_base_url"].rstrip("/"),
            download_timeout_seconds=float(runtime["ota"]["download_timeout_seconds"]),
            updates_dir=Path(runtime["ota"]["updates_dir"]),
        ),
        scanner=ScannerSettings(
            char_timeout_seconds=float(runtime["scanner"]["char_timeout_seconds"]),
        ),
        storage=StorageSettings(
            queue_dir=Path(runtime["storage"]["queue_dir"]),
            log_dir=Path(runtime["storage"]["log_dir"]),
        ),
        runtime=RuntimeSettings(
            log_level=runtime["runtime"]["log_level"].upper(),
            reconnect_min_seconds=runtime["runtime"]["reconnect_min_seconds"],
            reconnect_max_seconds=runtime["runtime"]["reconnect_max_seconds"],
            config_poll_seconds=float(runtime["runtime"]["config_poll_seconds"]),
        ),
    )


def generate_key() -> bytes:
    return AESGCM.generate_key(bit_length=256)


def encrypt_credentials(credentials: dict[str, Any], key: bytes) -> bytes:
    validate_credentials(credentials)
    if len(key) != 32:
        raise ConfigError("master key must contain exactly 32 bytes")
    nonce = os.urandom(12)
    plaintext = json.dumps(credentials, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ciphertext = AESGCM(key).encrypt(nonce, plaintext, SECRET_AAD)
    envelope = {
        "version": CONFIG_VERSION,
        "nonce": base64.b64encode(nonce).decode("ascii"),
        "ciphertext": base64.b64encode(ciphertext).decode("ascii"),
    }
    return (json.dumps(envelope, sort_keys=True) + "\n").encode("utf-8")


def decrypt_credentials(payload: bytes, key: bytes) -> dict[str, Any]:
    try:
        envelope = json.loads(payload.decode("utf-8"))
        if envelope.get("version") != CONFIG_VERSION:
            raise ConfigError("unsupported encrypted credentials version")
        nonce = base64.b64decode(envelope["nonce"], validate=True)
        ciphertext = base64.b64decode(envelope["ciphertext"], validate=True)
        plaintext = AESGCM(key).decrypt(nonce, ciphertext, SECRET_AAD)
        document = json.loads(plaintext.decode("utf-8"))
    except ConfigError:
        raise
    except Exception as exc:
        raise ConfigError("credentials cannot be decrypted or are corrupted") from exc
    return validate_credentials(document)


def _set_secure_permissions(path: Path, mode: int, uid: int | None, gid: int | None) -> None:
    try:
        os.chmod(path, mode)
    except OSError:
        pass
    if uid is not None or gid is not None:
        try:
            os.chown(path, -1 if uid is None else uid, -1 if gid is None else gid)
        except (AttributeError, OSError):
            pass


def atomic_write(
    path: Path,
    payload: bytes,
    *,
    mode: int = 0o640,
    uid: int | None = None,
    gid: int | None = None,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        _set_secure_permissions(temporary_path, mode, uid, gid)
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


class ConfigStore:
    def __init__(
        self,
        config_path: Path = DEFAULT_CONFIG_PATH,
        credentials_path: Path = DEFAULT_CREDENTIALS_PATH,
        key_path: Path = DEFAULT_KEY_PATH,
    ) -> None:
        self.config_path = Path(config_path)
        self.credentials_path = Path(credentials_path)
        self.key_path = Path(key_path)

    def read_runtime(self) -> dict[str, Any]:
        try:
            document = yaml.safe_load(self.config_path.read_text(encoding="utf-8"))
        except FileNotFoundError as exc:
            raise ConfigError(f"configuration file not found: {self.config_path}") from exc
        except yaml.YAMLError as exc:
            raise ConfigError(f"configuration YAML is invalid: {exc}") from exc
        return validate_runtime(document)

    def read_key(self) -> bytes:
        try:
            key = self.key_path.read_bytes()
        except FileNotFoundError as exc:
            raise ConfigError(f"master key not found: {self.key_path}") from exc
        if len(key) != 32:
            raise ConfigError("master key must contain exactly 32 bytes")
        return key

    def read_credentials(self) -> dict[str, Any]:
        try:
            payload = self.credentials_path.read_bytes()
        except FileNotFoundError as exc:
            raise ConfigError(f"credentials file not found: {self.credentials_path}") from exc
        return decrypt_credentials(payload, self.read_key())

    def load(self) -> Settings:
        return parse_settings(self.read_runtime(), self.read_credentials())

    def fingerprint(self) -> str:
        digest = hashlib.sha256()
        for path in (self.config_path, self.credentials_path):
            try:
                digest.update(path.read_bytes())
            except OSError as exc:
                digest.update(f"{path}:{exc}".encode("utf-8"))
        return digest.hexdigest()

    def write_runtime(self, document: dict[str, Any]) -> None:
        validate_runtime(document)
        payload = yaml.safe_dump(document, sort_keys=False).encode("utf-8")
        atomic_write(self.config_path, payload, mode=0o644)

    def write_credentials(self, document: dict[str, Any]) -> None:
        payload = encrypt_credentials(document, self.read_key())
        atomic_write(self.credentials_path, payload, mode=0o640, gid=10001)


class SettingsWatcher:
    """Poll a configuration directory while retaining the last-known-good settings."""

    def __init__(
        self,
        store: ConfigStore,
        on_error: Callable[[str], None] | None = None,
    ) -> None:
        self.store = store
        self.on_error = on_error or (lambda _message: None)
        self.settings = store.load()
        self._observed_fingerprint = store.fingerprint()

    def poll(self) -> Settings | None:
        fingerprint = self.store.fingerprint()
        if fingerprint == self._observed_fingerprint:
            return None
        self._observed_fingerprint = fingerprint
        try:
            candidate = self.store.load()
        except ConfigError as exc:
            self.on_error(str(exc))
            return None
        if candidate == self.settings:
            return None
        self.settings = candidate
        return candidate


def clone_default_runtime() -> dict[str, Any]:
    return json.loads(json.dumps(DEFAULT_RUNTIME))


def clone_default_credentials() -> dict[str, Any]:
    return json.loads(json.dumps(DEFAULT_CREDENTIALS))
