# Counter Inspect Docker deployment

This directory packages the MQTT bridge, OTA handler, and barcode scanner as
independent containers built from one ARM64 Python image. A fourth container
serves the downloaded OTA files at `/updates/`.

## Orange Pi prerequisites

- AArch64 Debian/Ubuntu-based OS
- Docker Engine with the Compose v2 plugin
- A running local Mosquitto broker that accepts connections from Docker's
  bridge gateway (the default client host is `host.docker.internal`)
- An active X11 desktop session; the scanner is treated as a keyboard emulator
- Host TCP port 80 available, unless `OTA_HTTP_PORT` is overridden

The credential CLI configures MQTT **clients only**. Create the matching users
on local and remote brokers before starting these services.

## First deployment

`counterctl` does not require a graphical session, so configuration can be
initialized first:

```sh
docker compose build
docker compose run --rm counterctl init \
  --device-id HAS-AI-0003
```

Before starting `scanner-inspect`, find the display and authorization file used
by the active graphical session. The `-auth` argument in the Xorg process is
the most reliable source on Armbian:

```sh
ls -l /tmp/.X11-unix/
ps -eo user,args | grep -E '[X]org|[X]wayland'
find /run/user /run /home -maxdepth 5 -type f \
  \( -name '.Xauthority' -o -name 'Xauthority' \) 2>/dev/null
```

Create `.env` with the matching absolute values. Do not assume
`/home/orangepi/.Xauthority` exists, and do not create an empty file: it would
not contain the authentication cookie. Do not use an authorization file from
an unrelated root SSH session.

```dotenv
OTA_HTTP_PORT=80
DISPLAY=:0
XAUTHORITY_PATH=/run/path/reported/by/xorg
```

Initialization prompts for local and remote MQTT usernames and passwords using
hidden password input. Validate the application configuration, then start the
deployment:

```sh
docker compose run --rm counterctl config validate
docker compose up -d
docker compose ps
```

`counterctl init` creates:

- `config/runtime.yaml`, containing non-secret settings
- `config/credentials.enc`, containing AES-256-GCM encrypted credentials
- a 256-bit encryption key in the `counter-inspect_counter_secret_key` Docker
  volume
- writable `logs`, `state/queue`, and `updates` directories

Do not run `docker compose down --volumes` unless the encryption key has been
backed up and you intend to destroy this deployment's stored credentials.

Docker's `unless-stopped` policy starts the containers again after host reboot
when the Docker daemon is enabled:

```sh
sudo systemctl enable --now docker
```

## Configuration and credential rotation

Show the effective configuration; passwords are always redacted:

```sh
docker compose run --rm counterctl config show
```

Edit an existing scalar setting using its dotted name:

```sh
docker compose run --rm counterctl config set brokers.remote.host mqtt.example.com
docker compose run --rm counterctl config set ota.source_base_url https://ota.example.com:9000
docker compose run --rm counterctl config set runtime.log_level DEBUG
docker compose run --rm counterctl config set scanner.char_timeout_seconds 0.2
```

Rotate client credentials:

```sh
docker compose run --rm counterctl credentials set local
docker compose run --rm counterctl credentials set remote
```

Configuration is schema-validated and written atomically. Running processes
poll for changes, retain their last-known-good settings after an invalid file,
and reconnect only the MQTT clients affected by an edit. No container restart
is needed for credentials, endpoints, device ID, scanner timing, logging level,
timeouts, or reconnect settings. A legacy `scanner.input_device` key is accepted
but ignored because X11 capture does not bind to a physical input device.

`config validate` deliberately does not require X11, allowing initialization
and credential recovery over SSH or on a headless system. The scanner's logs
report X11 connection or authentication failures.

Host port mappings and X11 mount settings remain Compose-level settings and
require `docker compose up -d --force-recreate scanner-inspect` after
modification. To move the OTA HTTP listener away from port 80, change `.env`:

```dotenv
OTA_HTTP_PORT=8080
```

The ESP32 server URL must include the same non-default port.

## OTA files

The OTA handler downloads these remote paths, preserving the existing API:

```text
<ota.source_base_url>/<device_id>/firmware/<version>.bin
<ota.source_base_url>/<device_id>/version/<version>.txt
```

It stages both responses in `updates/` and only replaces `firmware.bin` and
`version.txt` when both downloads succeed. The HTTP container then exposes:

```text
http://<orange-pi>/updates/firmware.bin
http://<orange-pi>/updates/version.txt
```

Check reachability from another machine before triggering OTA:

```sh
curl -f http://ORANGE_PI_IP/updates/version.txt
```

## Operations

Inspect status and logs:

```sh
docker compose ps
docker compose logs --tail=100 mqtt-bridge
docker compose logs --tail=100 ota-handler
docker compose logs --tail=100 scanner-inspect
docker compose logs --tail=100 updates-http
```

Persistent file logs are below `logs/<service>/`. Unsent jobsend messages are
kept below `state/queue/`. X11 session disconnects and broker outages are
retried without operator action. Scanner input is not suppressed, so scans also
continue to appear in the focused desktop application. Only rapid sequences
of at least two characters terminated by Enter are published; slower normal
keyboard typing and isolated keystrokes are discarded.

Before the first container deployment, disable legacy services so duplicate
processes do not publish the same MQTT messages or consume the same scanner:

```sh
sudo systemctl disable --now counter_mqtt_bridge.service
sudo systemctl disable --now scanner_inspect.service
sudo systemctl disable --now counter_ota.service 2>/dev/null || true
```

## Encryption-key backup

The master key is deliberately separate from the encrypted configuration.
Back it up to protected removable storage; anyone with both files can decrypt
the broker passwords.

```sh
mkdir -p key-backup
chmod 700 key-backup
docker run --rm \
  -v counter-inspect_counter_secret_key:/key:ro \
  -v "$PWD/key-backup:/backup" \
  alpine:3.20 sh -c 'umask 077; cp /key/master.key /backup/master.key'
```

Never commit the key, `runtime.yaml`, `credentials.enc`, logs, queue files, or
downloaded firmware. Root access to the Orange Pi or Docker daemon remains a
trusted administrative boundary; encryption does not protect against a fully
compromised host.

## Development verification

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements-dev.txt
pytest -q
docker compose config --quiet
docker buildx build --platform linux/arm64 --load -t counter-inspect:1.0.0 .
```
