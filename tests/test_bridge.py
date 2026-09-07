from __future__ import annotations

import json
import logging

import paho.mqtt.client as mqtt

from counter_inspect.bridge import BridgeService, LOCAL_TOPICS
from counter_inspect.config import clone_default_credentials, clone_default_runtime, parse_settings


class PublishResult:
    def __init__(self, rc=mqtt.MQTT_ERR_SUCCESS):
        self.rc = rc


class FakeClient:
    def __init__(self, rc=mqtt.MQTT_ERR_SUCCESS):
        self.rc = rc
        self.messages = []

    def publish(self, topic, payload):
        self.messages.append((topic, payload))
        return PublishResult(self.rc)


class Message:
    def __init__(self, topic, payload):
        self.topic = topic
        self.payload = payload.encode("utf-8")


def make_settings(tmp_path):
    runtime = clone_default_runtime()
    runtime["device_id"] = "HAS-AI-0003"
    runtime["storage"]["queue_dir"] = str(tmp_path / "queue")
    runtime["storage"]["log_dir"] = str(tmp_path / "logs")
    return parse_settings(runtime, clone_default_credentials())


def test_remote_messages_are_filtered_by_shared_device_id(tmp_path):
    service = BridgeService(make_settings(tmp_path), logging.getLogger("bridge-filter-test"))
    local = FakeClient()
    service.local_client = local

    service._on_message_remote(
        None,
        None,
        Message("config/config", json.dumps({"mesin_id": "OTHER", "cmd": "reboot"})),
    )
    assert local.messages == []

    payload = json.dumps({"mesin_id": "HAS-AI-0003", "cmd": "reboot"})
    service._on_message_remote(None, None, Message("config/config", payload))
    assert local.messages == [("config/config", payload)]


def test_failed_jobsend_is_saved_and_flushed(tmp_path):
    service = BridgeService(make_settings(tmp_path), logging.getLogger("bridge-queue-test"))
    service.remote_client = FakeClient(mqtt.MQTT_ERR_NO_CONN)
    payload = '{"MESIN_ID":"HAS-AI-0003"}'
    service._on_message_local(None, None, Message(LOCAL_TOPICS[0], payload))
    queue_files = list(service.settings.storage.queue_dir.glob("jobsend_*.txt"))
    assert len(queue_files) == 1
    assert payload in queue_files[0].read_text(encoding="utf-8")

    healthy = FakeClient()
    service.remote_client = healthy
    service.flush_queue()
    assert healthy.messages == [(LOCAL_TOPICS[0], payload)]
    assert list(service.settings.storage.queue_dir.glob("jobsend_*.txt")) == []
