from __future__ import annotations

import json
import logging
import threading
import time
from dataclasses import dataclass

import paho.mqtt.client as mqtt

from .config import ConfigStore, Settings, SettingsWatcher
from .logging_utils import configure_logging
from .mqtt_utils import create_client, start_client, stop_client
from .runtime import Shutdown, touch_heartbeat


TOPIC_EMPLOYEE = "counter/label"
TOPIC_ITEM = "counter/label-sku"
MINIMUM_SCAN_LENGTH = 2


@dataclass(frozen=True)
class Scan:
    barcode: str


class KeyboardScanBuffer:
    """Collect fast keyboard-emulator input and reject normal slow typing."""

    def __init__(self, timeout_seconds: float, minimum_length: int = MINIMUM_SCAN_LENGTH) -> None:
        self.timeout_seconds = timeout_seconds
        self.minimum_length = minimum_length
        self.barcode = ""
        self.last_key_time: float | None = None

    def reset(self) -> None:
        self.barcode = ""
        self.last_key_time = None

    def feed(
        self,
        character: str | None = None,
        *,
        enter: bool = False,
        timestamp: float | None = None,
    ) -> Scan | None:
        now = time.monotonic() if timestamp is None else timestamp
        gap_timed_out = (
            self.last_key_time is not None
            and now - self.last_key_time > self.timeout_seconds
        )

        if enter:
            if gap_timed_out or len(self.barcode) < self.minimum_length:
                self.reset()
                return None
            result = Scan(self.barcode)
            self.reset()
            return result

        if not character or not character.isprintable():
            return None
        if gap_timed_out:
            self.barcode = ""
        self.barcode += character
        self.last_key_time = now
        return None


class ScannerService:
    def __init__(self, settings: Settings, logger: logging.Logger) -> None:
        self.settings = settings
        self.logger = logger
        self.client: mqtt.Client | None = None
        self.listener = None
        self.buffer = KeyboardScanBuffer(settings.scanner.char_timeout_seconds)
        self._buffer_lock = threading.Lock()
        self._listener_lock = threading.RLock()
        self._next_listener_attempt = 0.0

    def start(self) -> None:
        self._replace_client()
        self._open_listener()
        self.logger.info("Scanner service started for device %s", self.settings.device_id)

    def stop(self) -> None:
        self._close_listener()
        client, self.client = self.client, None
        stop_client(client)
        self.logger.info("Scanner service stopped")

    def reload(self, candidate: Settings) -> None:
        previous = self.settings
        mqtt_changed = (
            candidate.device_id != previous.device_id
            or candidate.local_broker != previous.local_broker
            or candidate.runtime.reconnect_min_seconds
            != previous.runtime.reconnect_min_seconds
            or candidate.runtime.reconnect_max_seconds
            != previous.runtime.reconnect_max_seconds
        )
        scanner_changed = candidate.scanner != previous.scanner
        self.settings = candidate
        if (
            candidate.storage.log_dir != previous.storage.log_dir
            or candidate.runtime.log_level != previous.runtime.log_level
        ):
            self.logger = configure_logging(
                "scanner-inspect",
                candidate.storage.log_dir,
                candidate.runtime.log_level,
            )
        if mqtt_changed:
            self._replace_client()
        if scanner_changed:
            with self._buffer_lock:
                self.buffer = KeyboardScanBuffer(
                    candidate.scanner.char_timeout_seconds
                )
        self.logger.info("Applied updated configuration")

    def _replace_client(self) -> None:
        client = create_client(
            f"scanner_inspect_{self.settings.device_id}",
            self.settings.local_broker,
            self.settings.runtime,
        )
        client.on_connect = self._on_connect
        client.on_disconnect = self._on_disconnect
        previous, self.client = self.client, client
        stop_client(previous)
        start_client(client, self.settings.local_broker)

    def _on_connect(
        self, _client, _userdata, _flags, reason_code, _properties
    ) -> None:
        if reason_code == 0:
            self.logger.info("Connected to local MQTT broker")
        else:
            self.logger.error("Local MQTT connection failed: %s", reason_code)

    def _on_disconnect(
        self, _client, _userdata, _flags, reason_code, _properties
    ) -> None:
        if reason_code != 0:
            self.logger.warning(
                "Disconnected from local MQTT broker: %s", reason_code
            )

    def _open_listener(self) -> None:
        with self._listener_lock:
            if self.listener is not None and self.listener.running:
                return
            self._close_listener()
            if time.monotonic() < self._next_listener_attempt:
                return
            try:
                from pynput import keyboard

                listener = keyboard.Listener(on_press=self._on_key_press)
                listener.start()
                self.listener = listener
                self.logger.info("Listening for scanner keystrokes on the X11 desktop")
            except Exception as exc:
                self.listener = None
                self._next_listener_attempt = (
                    time.monotonic()
                    + self.settings.runtime.reconnect_min_seconds
                )
                self.logger.error("Cannot start X11 keyboard listener: %s", exc)

    def _close_listener(self) -> None:
        with self._listener_lock:
            listener, self.listener = self.listener, None
        if listener is not None:
            try:
                listener.stop()
                listener.join(timeout=2)
            except (RuntimeError, OSError):
                pass

    def _on_key_press(self, key) -> None:
        try:
            from pynput import keyboard

            is_enter = key in {keyboard.Key.enter}
            character = None
            if not is_enter:
                if key == keyboard.Key.space:
                    character = " "
                elif getattr(key, "char", None) is not None:
                    character = key.char
            with self._buffer_lock:
                scan = self.buffer.feed(character, enter=is_enter)
            if scan:
                self.publish_scan(scan.barcode)
        except Exception as exc:
            self.logger.error("Keyboard event processing failed: %s", exc)

    def poll_keyboard(self, timeout: float) -> None:
        with self._listener_lock:
            running = self.listener is not None and self.listener.running
        if not running:
            self._open_listener()
        time.sleep(timeout)

    def publish_scan(self, barcode: str) -> None:
        payload: dict[str, object] = {
            "serialNumber": self.settings.device_id,
            "serverTime": int(time.time()),
        }
        if "/employee-profile/" in barcode:
            topic = TOPIC_EMPLOYEE
            payload["employeeNik"] = barcode.split("/employee-profile/", 1)[1]
        else:
            topic = TOPIC_ITEM
            payload["skuCode"] = barcode
        message = json.dumps(payload, indent=4)
        self.logger.info("Scanned on %s: %s", topic, message)
        if self.client is None or not self.client.is_connected():
            self.logger.warning("MQTT is disconnected; scan was not published")
            return
        result = self.client.publish(topic, message)
        if result.rc != mqtt.MQTT_ERR_SUCCESS:
            self.logger.warning("Scan publish failed with code %s", result.rc)


def main() -> int:
    store = ConfigStore()
    settings = store.load()
    logger = configure_logging(
        "scanner-inspect", settings.storage.log_dir, settings.runtime.log_level
    )
    watcher = SettingsWatcher(
        store,
        lambda message: logger.error(
            "Rejected configuration update: %s", message
        ),
    )
    service = ScannerService(settings, logger)
    shutdown = Shutdown()
    shutdown.install()
    service.start()
    try:
        while not shutdown.event.is_set():
            candidate = watcher.poll()
            if candidate:
                service.reload(candidate)
            service.poll_keyboard(
                min(0.5, watcher.settings.runtime.config_poll_seconds)
            )
            touch_heartbeat()
    finally:
        service.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
