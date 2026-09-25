from __future__ import annotations

import json
import logging

import paho.mqtt.client as mqtt

from counter_inspect.config import clone_default_credentials, clone_default_runtime, parse_settings
from counter_inspect.scanner import KeyboardScanBuffer, ScannerService, TOPIC_EMPLOYEE


class FakePublishResult:
    rc = mqtt.MQTT_ERR_SUCCESS


class FakeClient:
    def __init__(self):
        self.messages = []

    def is_connected(self):
        return True

    def publish(self, topic, payload):
        self.messages.append((topic, payload))
        return FakePublishResult()


def make_service(tmp_path):
    runtime = clone_default_runtime()
    runtime["device_id"] = "HAS-AI-0016"
    runtime["storage"]["log_dir"] = str(tmp_path / "logs")
    runtime["storage"]["queue_dir"] = str(tmp_path / "queue")
    runtime["ota"]["updates_dir"] = str(tmp_path / "updates")
    settings = parse_settings(runtime, clone_default_credentials())
    service = ScannerService(settings, logging.getLogger("scanner-publish-test"))
    service.client = FakeClient()
    return service


def type_text(
    buffer: KeyboardScanBuffer,
    text: str,
    start: float = 1.0,
    gap: float = 0.01,
) -> float:
    timestamp = start
    for character in text:
        buffer.feed(character, timestamp=timestamp)
        timestamp += gap
    return timestamp


def test_fast_employee_url_is_accepted():
    buffer = KeyboardScanBuffer(0.2)
    timestamp = type_text(buffer, "https://host/employee-profile/1234")
    scan = buffer.feed(enter=True, timestamp=timestamp)
    assert scan is not None
    assert scan.barcode == "https://host/employee-profile/1234"


def test_mangled_employee_url_is_normalized_and_published_as_employee(tmp_path):
    service = make_service(tmp_path)

    service.publish_scan(
        "https>&&berdikari.indonesiaornamenteknologi.co.id&employee/profile&HR/EMP/02006"
    )

    assert len(service.client.messages) == 1
    topic, encoded_payload = service.client.messages[0]
    payload = json.loads(encoded_payload)
    assert topic == TOPIC_EMPLOYEE
    assert payload["employeeNik"] == "HR-EMP-02006"


def test_employee_url_detection_is_case_insensitive(tmp_path):
    service = make_service(tmp_path)

    service.publish_scan("HTTPS://HOST/EMPLOYEE-PROFILE/HR-EMP-02006")

    topic, encoded_payload = service.client.messages[0]
    payload = json.loads(encoded_payload)
    assert topic == TOPIC_EMPLOYEE
    assert payload["employeeNik"] == "HR-EMP-02006"


def test_slow_human_typing_is_rejected():
    buffer = KeyboardScanBuffer(0.2)
    timestamp = type_text(buffer, "human input", gap=0.3)
    assert buffer.feed(enter=True, timestamp=timestamp) is None


def test_delayed_enter_is_rejected():
    buffer = KeyboardScanBuffer(0.2)
    timestamp = type_text(buffer, "SKU-123")
    assert buffer.feed(enter=True, timestamp=timestamp + 0.3) is None


def test_fast_spaces_and_punctuation_are_preserved():
    buffer = KeyboardScanBuffer(0.2)
    timestamp = type_text(buffer, "AB 12/34-5")
    scan = buffer.feed(enter=True, timestamp=timestamp)
    assert scan is not None
    assert scan.barcode == "AB 12/34-5"


def test_single_character_sequence_is_rejected():
    buffer = KeyboardScanBuffer(0.2)
    buffer.feed("A", timestamp=1.0)
    assert buffer.feed(enter=True, timestamp=1.01) is None


def test_non_printable_keys_are_ignored():
    buffer = KeyboardScanBuffer(0.2)
    buffer.feed("A", timestamp=1.0)
    buffer.feed("\x00", timestamp=1.01)
    buffer.feed("B", timestamp=1.02)
    scan = buffer.feed(enter=True, timestamp=1.03)
    assert scan is not None
    assert scan.barcode == "AB"
