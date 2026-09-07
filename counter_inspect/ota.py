from __future__ import annotations

import json
import logging
import os
import tempfile
import threading
from pathlib import Path
from urllib.parse import quote

import paho.mqtt.client as mqtt
import requests

from .config import ConfigStore, Settings, SettingsWatcher
from .logging_utils import configure_logging
from .mqtt_utils import create_client, start_client, stop_client
from .runtime import Shutdown, service_loop


MQTT_TOPIC = "counter/ota"
MQTT_TOPIC_COMMAND = "config/config"


class OtaService:
    def __init__(self, settings: Settings, logger: logging.Logger) -> None:
        self.settings = settings
        self.logger = logger
        self.client: mqtt.Client | None = None
        self._client_lock = threading.RLock()
        self._download_lock = threading.Lock()

    def start(self) -> None:
        self._replace_client()
        self.logger.info("OTA handler started for device %s", self.settings.device_id)

    def stop(self) -> None:
        with self._client_lock:
            client = self.client
            self.client = None
        stop_client(client)
        self.logger.info("OTA handler stopped")

    def reload(self, candidate: Settings) -> None:
        previous = self.settings
        reconnect = (
            candidate.device_id != previous.device_id
            or candidate.remote_broker != previous.remote_broker
            or candidate.runtime.reconnect_min_seconds != previous.runtime.reconnect_min_seconds
            or candidate.runtime.reconnect_max_seconds != previous.runtime.reconnect_max_seconds
        )
        self.settings = candidate
        if candidate.storage.log_dir != previous.storage.log_dir or candidate.runtime.log_level != previous.runtime.log_level:
            self.logger = configure_logging("ota-handler", candidate.storage.log_dir, candidate.runtime.log_level)
        if reconnect:
            self._replace_client()
        self.logger.info("Applied updated configuration")

    def _replace_client(self) -> None:
        client = create_client(
            f"counter_ota_{self.settings.device_id}",
            self.settings.remote_broker,
            self.settings.runtime,
        )
        client.on_connect = self._on_connect
        client.on_disconnect = self._on_disconnect
        client.on_message = self._on_message
        with self._client_lock:
            previous = self.client
            self.client = client
        stop_client(previous)
        start_client(client, self.settings.remote_broker)

    def _on_connect(self, client, _userdata, _flags, reason_code, _properties) -> None:
        if reason_code == 0:
            client.subscribe(MQTT_TOPIC)
            self.logger.info("Connected to remote MQTT broker and subscribed to %s", MQTT_TOPIC)
        else:
            self.logger.error("Remote MQTT connection failed: %s", reason_code)

    def _on_disconnect(self, _client, _userdata, _flags, reason_code, _properties) -> None:
        if reason_code != 0:
            self.logger.warning("Disconnected from remote MQTT broker: %s", reason_code)

    def _on_message(self, _client, _userdata, message) -> None:
        if message.topic != MQTT_TOPIC:
            return
        try:
            document = json.loads(message.payload.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self.logger.warning("Ignored invalid OTA command payload")
            return
        if document.get("mesin_id") != self.settings.device_id or document.get("cmd") != "download":
            return
        version = document.get("version")
        if not isinstance(version, str) or not version.strip() or len(version) > 128:
            self.logger.warning("Ignored OTA command with invalid version")
            return
        if not self._download_lock.acquire(blocking=False):
            self.logger.warning("Ignored OTA command because another download is active")
            return
        snapshot = self.settings
        thread = threading.Thread(
            target=self._process_download,
            args=(snapshot, version.strip()),
            name="ota-download",
            daemon=True,
        )
        thread.start()

    def _process_download(self, settings: Settings, version: str) -> None:
        try:
            self.download_update(settings, version)
            payload = json.dumps({"mesin_id": settings.device_id, "cmd": "reboot_ota"})
            with self._client_lock:
                client = self.client
            if client is None:
                raise RuntimeError("MQTT client unavailable after OTA download")
            result = client.publish(MQTT_TOPIC_COMMAND, payload)
            if result.rc != mqtt.MQTT_ERR_SUCCESS:
                raise RuntimeError(f"reboot command publish failed with code {result.rc}")
            self.logger.info("OTA files installed and reboot command published for version %s", version)
        except Exception as exc:
            self.logger.error("OTA download failed for version %s: %s", version, exc)
        finally:
            self._download_lock.release()

    def _download_to_temp(self, url: str, directory: Path, timeout: float) -> Path:
        descriptor, temporary_name = tempfile.mkstemp(prefix=".ota-", dir=directory)
        temporary = Path(temporary_name)
        try:
            with os.fdopen(descriptor, "wb") as output, requests.get(
                url,
                stream=True,
                timeout=(min(timeout, 10), timeout),
            ) as response:
                response.raise_for_status()
                total = 0
                for chunk in response.iter_content(chunk_size=64 * 1024):
                    if chunk:
                        output.write(chunk)
                        total += len(chunk)
                if total == 0:
                    raise ValueError("downloaded file is empty")
                output.flush()
                os.fsync(output.fileno())
            os.chmod(temporary, 0o644)
            return temporary
        except Exception:
            temporary.unlink(missing_ok=True)
            raise

    def download_update(self, settings: Settings, version: str) -> None:
        updates_dir = settings.ota.updates_dir
        updates_dir.mkdir(parents=True, exist_ok=True)
        encoded_device = quote(settings.device_id, safe="")
        encoded_version = quote(version, safe="")
        base = settings.ota.source_base_url.rstrip("/")
        firmware_url = f"{base}/{encoded_device}/firmware/{encoded_version}.bin"
        version_url = f"{base}/{encoded_device}/version/{encoded_version}.txt"
        self.logger.info("Downloading OTA firmware from %s", firmware_url)
        firmware_temp: Path | None = None
        version_temp: Path | None = None
        try:
            firmware_temp = self._download_to_temp(
                firmware_url, updates_dir, settings.ota.download_timeout_seconds
            )
            version_temp = self._download_to_temp(
                version_url, updates_dir, settings.ota.download_timeout_seconds
            )
            os.replace(firmware_temp, updates_dir / "firmware.bin")
            firmware_temp = None
            os.replace(version_temp, updates_dir / "version.txt")
            version_temp = None
        finally:
            if firmware_temp is not None:
                firmware_temp.unlink(missing_ok=True)
            if version_temp is not None:
                version_temp.unlink(missing_ok=True)


def main() -> int:
    store = ConfigStore()
    settings = store.load()
    logger = configure_logging("ota-handler", settings.storage.log_dir, settings.runtime.log_level)
    watcher = SettingsWatcher(store, lambda message: logger.error("Rejected configuration update: %s", message))
    service = OtaService(settings, logger)
    shutdown = Shutdown()
    shutdown.install()
    service.start()
    try:
        service_loop(
            shutdown,
            lambda: watcher.settings.runtime.config_poll_seconds,
            lambda: service.reload(candidate) if (candidate := watcher.poll()) else None,
        )
    finally:
        service.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
