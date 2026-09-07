from __future__ import annotations

import logging

from counter_inspect.bridge import BridgeService
from counter_inspect.config import clone_default_credentials, clone_default_runtime, parse_settings
from counter_inspect.ota import OtaService
from counter_inspect.scanner import ScannerService


def settings_with_credentials(tmp_path, local_password="local-1", remote_password="remote-1"):
    runtime = clone_default_runtime()
    runtime["device_id"] = "HAS-AI-0003"
    runtime["storage"]["queue_dir"] = str(tmp_path / "queue")
    runtime["storage"]["log_dir"] = str(tmp_path / "logs")
    runtime["ota"]["updates_dir"] = str(tmp_path / "updates")
    credentials = clone_default_credentials()
    credentials["brokers"]["local"] = {"username": "local", "password": local_password}
    credentials["brokers"]["remote"] = {"username": "remote", "password": remote_password}
    return parse_settings(runtime, credentials)


def test_bridge_reconnects_only_remote_client_for_remote_credential_change(monkeypatch, tmp_path):
    service = BridgeService(settings_with_credentials(tmp_path), logging.getLogger("bridge-reload-test"))
    replacements = []
    monkeypatch.setattr(service, "_replace_local", lambda: replacements.append("local"))
    monkeypatch.setattr(service, "_replace_remote", lambda: replacements.append("remote"))

    service.reload(settings_with_credentials(tmp_path, remote_password="remote-2"))

    assert replacements == ["remote"]


def test_ota_reconnects_for_remote_credential_change(monkeypatch, tmp_path):
    service = OtaService(settings_with_credentials(tmp_path), logging.getLogger("ota-reload-test"))
    replacements = []
    monkeypatch.setattr(service, "_replace_client", lambda: replacements.append("remote"))

    service.reload(settings_with_credentials(tmp_path, remote_password="remote-2"))

    assert replacements == ["remote"]


def test_scanner_reconnects_for_local_credential_change(monkeypatch, tmp_path):
    service = ScannerService(settings_with_credentials(tmp_path), logging.getLogger("scanner-reload-test"))
    replacements = []
    monkeypatch.setattr(service, "_replace_client", lambda: replacements.append("local"))

    service.reload(settings_with_credentials(tmp_path, local_password="local-2"))

    assert replacements == ["local"]
