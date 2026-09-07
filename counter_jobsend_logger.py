import json
import paho.mqtt.client as mqtt
from datetime import datetime

# ====== CONFIGURATION ======
BROKER_ADDRESS = "192.168.100.38"       # or your MQTT broker IP
BROKER_PORT = 1883
BROKER_USER = "andon_gateway"
BROKER_PASS = "andon_gateway"
TOPIC = "counter/mesin/jobsend"
FILTER_MESIN_ID = "HAS-Q004"
OUTPUT_FILE = "filtered_messages.txt"
RECONNECT_DELAY = 3  # seconds
# ============================

def on_connect(client, userdata, flags, reason_code, properties):
    if reason_code == 0:
        print("✅ Connected to MQTT broker.")
        client.subscribe(TOPIC)
        print(f"📡 Subscribed to topic: {TOPIC}")
    else:
        print(f"❌ Connection failed. Reason code: {reason_code}")

def on_disconnect(client, userdata, disconnect_flags, reason_code, properties):
    print(f"⚠️ Disconnected from broker. Reason code: {reason_code}")
    print(f"🔁 Reconnecting in {RECONNECT_DELAY} seconds...")
    time.sleep(RECONNECT_DELAY)
    try:
        client.reconnect()
    except Exception as e:
        print(f"❌ Reconnect failed: {e}")
        time.sleep(RECONNECT_DELAY)

def on_message(client, userdata, message):
    try:
        payload = message.payload.decode("utf-8")
        data = json.loads(payload)

        # Ignore messages that don't match MESIN_ID
        if data.get("MESIN_ID") != FILTER_MESIN_ID:
            print("ℹ️ Message MESIN_ID does not match filter, ignored.")
            return

        # Append valid message to file
        output_file = get_output_filename()
        with open(output_file, "a") as f:
            f.write(payload + "\n")

        print(f"💾 Saved message from {FILTER_MESIN_ID}")

    except json.JSONDecodeError:
        print("⚠️ Invalid JSON received, ignored.")
    except Exception as e:
        print(f"⚠️ Error processing message: {e}")

def get_output_filename():
    """Generate a file name with today's date."""
    date_str = datetime.now().strftime("%Y-%m-%d")
    return f"jobsend_log/filtered_messages_{date_str}.txt"

def main():
    client = mqtt.Client(callback_api_version=mqtt.CallbackAPIVersion.VERSION2)
    client.username_pw_set(BROKER_USER, BROKER_PASS)

    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    client.on_message = on_message

    while True:
        try:
            print("🚀 Connecting to MQTT broker...")
            client.connect(BROKER_ADDRESS, BROKER_PORT, 60)
            client.loop_forever()
        except Exception as e:
            print(f"❌ Connection error: {e}")
            print(f"🔁 Retrying in {RECONNECT_DELAY} seconds...")
            time.sleep(RECONNECT_DELAY)

if __name__ == "__main__":
    main()