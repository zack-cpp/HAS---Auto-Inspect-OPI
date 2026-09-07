from __future__ import annotations

import copy
import json

import pytest

from counter_inspect.config import (
    ConfigError,
    ConfigStore,
    SettingsWatcher,
    clone_default_credentials,
    clone_default_runtime,
    decrypt_credentials,
    encrypt_credentials,
    generate_key,
)


def initialized_store(tmp_path):
    store = ConfigStore(
        tmp_path / "config" / "runtime.yaml",
        tmp_path / "config" / "credentials.enc",
        tmp_path / "key" / "master.key",
    )
    store.key_path.parent.mkdir(parents=True)
    store.key_path.write_bytes(generate_key())
    runtime = clone_default_runtime()
    runtime["device_id"] = "HAS-AI-0003"
    store.write_runtime(runtime)
    credentials = clone_default_credentials()
    credentials["brokers"]["local"] = {"username": "local-user", "password": "local-pass"}
    credentials["brokers"]["remote"] = {"username": "remote-user", "password": "remote-pass"}
    store.write_credentials(credentials)
    return store


def test_credentials_round_trip_and_do_not_leak_plaintext():
    key = generate_key()
    credentials = clone_default_credentials()
    credentials["brokers"]["remote"]["password"] = "very-secret-password"
    encrypted = encrypt_credentials(credentials, key)
    assert b"very-secret-password" not in encrypted
    assert decrypt_credentials(encrypted, key) == credentials


def test_corrupted_credentials_are_rejected():
    key = generate_key()
    envelope = json.loads(encrypt_credentials(clone_default_credentials(), key))
    replacement = "A" if envelope["ciphertext"][0] != "A" else "B"
    envelope["ciphertext"] = replacement + envelope["ciphertext"][1:]
    encrypted = json.dumps(envelope).encode("utf-8")
    with pytest.raises(ConfigError, match="cannot be decrypted|corrupted"):
        decrypt_credentials(encrypted, key)


def test_store_loads_typed_settings(tmp_path):
    settings = initialized_store(tmp_path).load()
    assert settings.device_id == "HAS-AI-0003"
    assert settings.local_broker.credentials.username == "local-user"
    assert settings.remote_broker.credentials.password == "remote-pass"


def test_legacy_scanner_input_device_is_accepted_but_ignored(tmp_path):
    store = initialized_store(tmp_path)
    runtime = store.read_runtime()
    runtime["scanner"]["input_device"] = "/dev/input/event9"
    store.write_runtime(runtime)
    settings = store.load()
    assert settings.scanner.char_timeout_seconds == 0.2
    assert not hasattr(settings.scanner, "input_device")


def test_watcher_keeps_last_known_good_after_invalid_update(tmp_path):
    store = initialized_store(tmp_path)
    errors = []
    watcher = SettingsWatcher(store, errors.append)
    original = watcher.settings

    store.config_path.write_text("version: 1\ndevice_id: [invalid\n", encoding="utf-8")
    assert watcher.poll() is None
    assert watcher.settings == original
    assert errors

    runtime = clone_default_runtime()
    runtime["device_id"] = "HAS-AI-0004"
    store.write_runtime(runtime)
    updated = watcher.poll()
    assert updated is not None
    assert updated.device_id == "HAS-AI-0004"


def test_unknown_runtime_keys_are_rejected(tmp_path):
    store = initialized_store(tmp_path)
    runtime = copy.deepcopy(store.read_runtime())
    runtime["unexpected"] = True
    with pytest.raises(ConfigError, match="unknown keys"):
        store.write_runtime(runtime)
