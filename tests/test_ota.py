from __future__ import annotations

import logging

import pytest

from counter_inspect.config import clone_default_credentials, clone_default_runtime, parse_settings
from counter_inspect.ota import OtaService


class FakeResponse:
    def __init__(self, body: bytes, status_error: Exception | None = None):
        self.body = body
        self.status_error = status_error

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def raise_for_status(self):
        if self.status_error:
            raise self.status_error

    def iter_content(self, chunk_size):
        assert chunk_size > 0
        yield self.body


def make_settings(tmp_path):
    runtime = clone_default_runtime()
    runtime["device_id"] = "HAS-AI-0003"
    runtime["ota"]["updates_dir"] = str(tmp_path)
    return parse_settings(runtime, clone_default_credentials())


def test_download_stages_both_files_before_replacing(monkeypatch, tmp_path):
    settings = make_settings(tmp_path)
    service = OtaService(settings, logging.getLogger("ota-test"))
    responses = [FakeResponse(b"firmware"), FakeResponse(b"1.2.3\n")]
    monkeypatch.setattr("counter_inspect.ota.requests.get", lambda *_args, **_kwargs: responses.pop(0))

    service.download_update(settings, "1.2.3")

    assert (tmp_path / "firmware.bin").read_bytes() == b"firmware"
    assert (tmp_path / "version.txt").read_bytes() == b"1.2.3\n"


def test_failed_second_download_keeps_existing_files(monkeypatch, tmp_path):
    settings = make_settings(tmp_path)
    service = OtaService(settings, logging.getLogger("ota-test-failure"))
    (tmp_path / "firmware.bin").write_bytes(b"old-firmware")
    (tmp_path / "version.txt").write_bytes(b"old-version")
    responses = [FakeResponse(b"new-firmware"), FakeResponse(b"")]
    monkeypatch.setattr("counter_inspect.ota.requests.get", lambda *_args, **_kwargs: responses.pop(0))

    with pytest.raises(ValueError, match="empty"):
        service.download_update(settings, "2.0.0")

    assert (tmp_path / "firmware.bin").read_bytes() == b"old-firmware"
    assert (tmp_path / "version.txt").read_bytes() == b"old-version"
