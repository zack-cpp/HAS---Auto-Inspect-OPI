from __future__ import annotations

import paho.mqtt.client as mqtt

from .config import BrokerSettings, RuntimeSettings


def create_client(
    client_id: str,
    broker: BrokerSettings,
    runtime: RuntimeSettings,
) -> mqtt.Client:
    client = mqtt.Client(
        callback_api_version=mqtt.CallbackAPIVersion.VERSION2,
        client_id=client_id,
        protocol=mqtt.MQTTv311,
    )
    if broker.credentials.username or broker.credentials.password:
        client.username_pw_set(broker.credentials.username, broker.credentials.password)
    client.reconnect_delay_set(
        min_delay=runtime.reconnect_min_seconds,
        max_delay=runtime.reconnect_max_seconds,
    )
    return client


def start_client(client: mqtt.Client, broker: BrokerSettings) -> None:
    client.connect_async(broker.host, broker.port, keepalive=60)
    client.loop_start()


def stop_client(client: mqtt.Client | None) -> None:
    if client is None:
        return
    try:
        client.disconnect()
    except Exception:
        pass
    try:
        client.loop_stop()
    except Exception:
        pass
