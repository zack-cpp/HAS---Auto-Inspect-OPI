from __future__ import annotations

import logging
import sys
from types import SimpleNamespace

from counter_inspect.config import (
    clone_default_credentials,
    clone_default_runtime,
    parse_settings,
)
from counter_inspect.scanner import ScannerService


class FakeListener:
    instances = []

    def __init__(self, on_press):
        self.on_press = on_press
        self.running = False
        self.stopped = False
        self.joined = False
        self.instances.append(self)

    def start(self):
        self.running = True

    def stop(self):
        self.running = False
        self.stopped = True

    def join(self, timeout):
        assert timeout == 2
        self.joined = True


def make_service(tmp_path):
    runtime = clone_default_runtime()
    runtime["device_id"] = "HAS-AI-0003"
    runtime["storage"]["queue_dir"] = str(tmp_path / "queue")
    runtime["storage"]["log_dir"] = str(tmp_path / "logs")
    runtime["ota"]["updates_dir"] = str(tmp_path / "updates")
    settings = parse_settings(runtime, clone_default_credentials())
    return ScannerService(settings, logging.getLogger("x11-listener-test"))


def fake_pynput_module():
    return SimpleNamespace(
        keyboard=SimpleNamespace(
            Listener=FakeListener,
            Key=SimpleNamespace(enter=object(), space=object()),
        )
    )


def test_listener_starts_and_stops_cleanly(monkeypatch, tmp_path):
    FakeListener.instances.clear()
    monkeypatch.setitem(sys.modules, "pynput", fake_pynput_module())
    service = make_service(tmp_path)

    service._open_listener()
    listener = service.listener
    assert listener is not None
    assert listener.running

    service._close_listener()
    assert listener.stopped
    assert listener.joined
    assert service.listener is None


def test_stopped_listener_is_recreated(monkeypatch, tmp_path):
    FakeListener.instances.clear()
    monkeypatch.setitem(sys.modules, "pynput", fake_pynput_module())
    service = make_service(tmp_path)
    service._open_listener()
    first = service.listener
    first.running = False

    service.poll_keyboard(0)

    assert service.listener is not first
    assert len(FakeListener.instances) == 2
