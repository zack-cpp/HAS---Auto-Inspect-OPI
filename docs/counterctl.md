# `counterctl` operator guide

`counterctl` manages the Counter Inspect device configuration and encrypted
MQTT client credentials. It runs inside Docker, so the Orange Pi does not need
a host-side Python installation.

All examples assume the project is installed at:

```text
/root/counter_inspect/opi-app
```

Start each session from that directory:

```sh
cd /root/counter_inspect/opi-app
```

The general command form is:

```sh
docker compose run --rm counterctl <command> [arguments]
```

`docker compose run` creates a temporary management container. `--rm` removes
that container after the command finishes. It does not remove application
configuration, credentials, logs, queues, OTA files, or the encryption-key
volume.

## Command summary

| Command | Purpose | Restart required? |
|---|---|---|
| `counterctl init` | Create initial configuration, encryption key, and credentials | Start the services afterward |
| `counterctl config show` | Display effective settings with passwords redacted | No |
| `counterctl config set KEY VALUE` | Change one existing application setting | Usually no; mounted-path changes also need Compose updates |
| `counterctl config validate` | Validate schema, credentials, and writable data paths | No |
| `counterctl credentials set local` | Replace local MQTT client credentials | No |
| `counterctl credentials set remote` | Replace remote MQTT client credentials | No |

To display built-in help:

```sh
docker compose run --rm counterctl --help
docker compose run --rm counterctl init --help
docker compose run --rm counterctl config --help
docker compose run --rm counterctl config set --help
docker compose run --rm counterctl credentials --help
```

## First-time initialization

Initialize the device before starting the services:

```sh
docker compose run --rm counterctl init --device-id HAS-AI-STB
```

The command asks for four values interactively:

1. Local MQTT username.
2. Local MQTT password.
3. Local MQTT password confirmation.
4. Remote MQTT username, password, and confirmation.

Press Enter for an empty username and password if a broker intentionally
allows anonymous clients. Password input is hidden and is never accepted as a
command-line argument.

Initialization creates:

- `config/runtime.yaml` for non-secret application settings.
- `config/credentials.enc` for AES-256-GCM encrypted credentials.
- `/key/master.key` in the `counter-inspect_counter_secret_key` Docker volume.
- The persistent log, queue, and OTA output directories.

The ciphertext and encryption key are deliberately stored separately. Neither
the plaintext password nor the key is placed in `.env`, YAML, command history,
or application logs.

Initialization refuses to overwrite any existing configuration or key. The
following command replaces the runtime configuration, both broker credential
sets, and the encryption key:

```sh
docker compose run --rm counterctl init --force --device-id HAS-AI-STB
```

Use `--force` only when intentionally resetting the installation. Back up the
key and configuration first. A new key makes an older `credentials.enc` file
undecryptable.

The deprecated `--scanner-device` option is accepted only for compatibility
and is ignored. Scanner input is captured from the X11 keyboard session.

## Displaying the current configuration

Run:

```sh
docker compose run --rm counterctl config show
```

The command displays `runtime.yaml` together with credential status. MQTT
usernames are visible, but non-empty passwords appear as `<redacted>`:

```yaml
version: 1
device_id: HAS-AI-STB
brokers:
  local:
    host: host.docker.internal
    port: 1883
  remote:
    host: mqtt.example.com
    port: 1883
credentials:
  local:
    username: counter-local
    password: <redacted>
  remote:
    username: counter-remote
    password: <redacted>
```

This command also proves that the current master key can decrypt the
credential store. It never prints the actual passwords.

## Changing application settings

Use an existing dotted setting name followed by one scalar value:

```sh
docker compose run --rm counterctl config set <key> <value>
```

For example:

```sh
docker compose run --rm counterctl config set device_id HAS-AI-STB-02
```

The CLI parses the value as YAML, validates the complete configuration, and
writes it atomically. Invalid values are rejected without changing the active
file. Unknown keys and whole mappings/lists cannot be added with this command.

Most changes are detected within `runtime.config_poll_seconds`. The services
keep running, apply the valid configuration, and reconnect only the affected
MQTT clients. No manual container restart is needed.

### Device ID

Change the shared device ID:

```sh
docker compose run --rm counterctl config set device_id HAS-AI-STB-02
```

Rules:

- Length: 1 to 64 characters.
- The first character must be a letter or digit.
- Remaining characters may be letters, digits, `.`, `_`, or `-`.
- Spaces, slashes, and URL punctuation are not accepted.

The device ID is shared by all services. Changing it updates:

- Bridge local and remote MQTT client IDs.
- Filtering of remote messages whose `mesin_id` must match this value.
- OTA command targeting and OTA download URL paths.
- Scanner MQTT client ID.
- Scanner payload `serialNumber`.

The bridge, OTA handler, and scanner reconnect automatically after this change.
Ensure the server-side device registration and OTA directory use the new ID.

### Local MQTT broker

Change the local broker hostname or IP address:

```sh
docker compose run --rm counterctl config set brokers.local.host 192.168.50.10
```

Change its TCP port:

```sh
docker compose run --rm counterctl config set brokers.local.port 1883
```

`brokers.local.host` must be a non-empty hostname or IP address.
`brokers.local.port` must be an integer from 1 through 65535.

The default `host.docker.internal` resolves to the Orange Pi host through the
Compose `host-gateway` mapping. Use it when Mosquitto runs directly on the
Orange Pi rather than in this Compose project. The host broker must listen on
an address reachable from Docker; a broker listening only on `127.0.0.1` is
not reachable through the bridge gateway.

Changing the local endpoint reconnects:

- The local side of `mqtt-bridge`.
- The MQTT connection used by `scanner-inspect`.

### Remote MQTT broker

Change the remote broker hostname:

```sh
docker compose run --rm counterctl config set brokers.remote.host mqtt.example.com
```

Change its TCP port:

```sh
docker compose run --rm counterctl config set brokers.remote.port 1883
```

The hostname must be non-empty, and the port must be an integer from 1 through
65535. Do not include `mqtt://` or `tcp://` in the host value.

Changing the remote endpoint reconnects:

- The remote side of `mqtt-bridge`.
- `ota-handler`.

The current implementation uses ordinary MQTT TCP connections. Changing the
port alone does not enable MQTT TLS.

### OTA source

Change the remote OTA HTTP server:

```sh
docker compose run --rm counterctl config set ota.source_base_url https://ota.example.com:9000
```

Requirements:

- The URL must be absolute.
- Only `http://` and `https://` are accepted.
- A query string or fragment is not accepted.
- A trailing slash is optional and is removed internally.

The OTA handler constructs these URLs:

```text
<source_base_url>/<device_id>/firmware/<version>.bin
<source_base_url>/<device_id>/version/<version>.txt
```

Change the per-download timeout:

```sh
docker compose run --rm counterctl config set ota.download_timeout_seconds 60
```

The timeout must be a number from 1 through 600 seconds. OTA source and timeout
changes are live and do not reconnect MQTT because they are used by the next
download operation.

`ota.updates_dir` defaults to `/data/updates`:

```sh
docker compose run --rm counterctl config set ota.updates_dir /data/updates
```

It must be an absolute container path. Keep the default unless the matching
Compose bind mount is also changed. Changing a container path to an unmounted
location can make files non-persistent or unwritable and requires a Compose
recreate.

### Scanner timing

Change the maximum time allowed between characters in one scan:

```sh
docker compose run --rm counterctl config set scanner.char_timeout_seconds 0.2
```

The value must be from 0.01 through 10 seconds. The default is `0.2`. A smaller
value rejects more human typing but may reject a slowly configured scanner. A
larger value accepts slower scanners but increases the chance that normal
typing is interpreted as a barcode.

Only sequences of at least two printable characters followed by Enter are
published. If the gap before the next character or Enter exceeds the timeout,
the partial sequence is discarded or restarted.

The new timeout is applied without reopening X11 or reconnecting MQTT.

### Logging

Change the logging level:

```sh
docker compose run --rm counterctl config set runtime.log_level DEBUG
```

Accepted values are:

- `DEBUG`
- `INFO`
- `WARNING`
- `ERROR`
- `CRITICAL`

Values are normalized to uppercase. The services reconfigure logging without
restarting.

`storage.log_dir` defaults to `/data/logs`:

```sh
docker compose run --rm counterctl config set storage.log_dir /data/logs
```

The value must be an absolute container path. As with the OTA directory, do
not move it outside the configured Compose mounts without updating Compose and
recreating the affected containers.

### MQTT reconnection timing

Set the minimum and maximum retry delays:

```sh
docker compose run --rm counterctl config set runtime.reconnect_min_seconds 2
docker compose run --rm counterctl config set runtime.reconnect_max_seconds 30
```

Rules:

- `reconnect_min_seconds`: integer from 1 through 300.
- `reconnect_max_seconds`: integer from 1 through 3600.
- The maximum must be greater than or equal to the minimum.

Changing either value recreates all affected MQTT clients so the new retry
policy takes effect immediately.

When lowering both values, set the minimum first. When raising both values,
set the maximum first. This avoids a temporary invalid configuration where the
maximum is below the minimum.

### Configuration polling

Change how frequently services check for configuration updates:

```sh
docker compose run --rm counterctl config set runtime.config_poll_seconds 1.0
```

The value must be from 0.2 through 60 seconds. Smaller values apply changes
sooner but perform more frequent filesystem checks.

### Persistent bridge queue

`storage.queue_dir` defaults to `/data/queue`:

```sh
docker compose run --rm counterctl config set storage.queue_dir /data/queue
```

It must be an absolute container path. This directory stores unsent `jobsend`
messages until the remote broker is available. Keep it inside the persistent
Compose mount unless Compose is updated and the bridge is recreated.

### Complete application-setting reference

| Key | Type and valid range | Default | Main consumers | Live effect |
|---|---|---:|---|---|
| `version` | Integer; must remain `1` | `1` | All | Do not change |
| `device_id` | 1–64 permitted characters | `CHANGE-ME` | All Python services | Reconnects all MQTT clients |
| `brokers.local.host` | Non-empty string | `host.docker.internal` | Bridge, scanner | Reconnects local clients |
| `brokers.local.port` | Integer 1–65535 | `1883` | Bridge, scanner | Reconnects local clients |
| `brokers.remote.host` | Non-empty string | `andon-dev.web.id` | Bridge, OTA | Reconnects remote clients |
| `brokers.remote.port` | Integer 1–65535 | `1883` | Bridge, OTA | Reconnects remote clients |
| `ota.source_base_url` | Absolute HTTP(S) URL | `http://andon-dev.web.id:9000` | OTA | Used by the next download |
| `ota.download_timeout_seconds` | Number 1–600 | `30` | OTA | Used by the next download |
| `ota.updates_dir` | Absolute container path | `/data/updates` | OTA | Advanced; mount must match |
| `scanner.char_timeout_seconds` | Number 0.01–10 | `0.2` | Scanner | Replaces scan buffer |
| `storage.queue_dir` | Absolute container path | `/data/queue` | Bridge | Advanced; mount must match |
| `storage.log_dir` | Absolute container path | `/data/logs` | All Python services | Reconfigures logging |
| `runtime.log_level` | Named logging level | `INFO` | All Python services | Reconfigures logging |
| `runtime.reconnect_min_seconds` | Integer 1–300 | `2` | All MQTT clients | Recreates clients |
| `runtime.reconnect_max_seconds` | Integer 1–3600 | `30` | All MQTT clients | Recreates clients |
| `runtime.config_poll_seconds` | Number 0.2–60 | `1.0` | All Python services | Changes reload interval |

## Changing MQTT credentials

Broker credentials are not changed with `config set`. Use the dedicated hidden
input commands.

### Local broker credentials

```sh
docker compose run --rm counterctl credentials set local
```

This replaces the username and password used by:

- The local side of `mqtt-bridge`.
- `scanner-inspect`.

Both services notice the encrypted-file change and reconnect automatically.

### Remote broker credentials

```sh
docker compose run --rm counterctl credentials set remote
```

This replaces the username and password used by:

- The remote side of `mqtt-bridge`.
- `ota-handler`.

Both services reconnect automatically.

The CLI changes client credentials only. It does not create a Mosquitto user,
modify a remote broker account, or change a password on either broker. Update
the broker account externally first, then enter matching credentials here.

Passwords must not be placed in:

- `.env`
- `runtime.yaml`
- Shell command arguments
- Shell scripts
- Compose YAML
- Git

## Validating changes

Run validation after initialization and after a group of edits:

```sh
docker compose run --rm counterctl config validate
```

Validation checks:

- Runtime YAML structure and supported configuration version.
- Device ID, ports, ranges, paths, and OTA URL format.
- Credential ciphertext integrity and decryptability with the mounted key.
- Existence and writability of queue, log, and OTA directories.
- Whether `device_id` still equals the `CHANGE-ME` placeholder.

It does not connect to either MQTT broker, download an OTA file, or validate
the X11 session. Use service logs for those runtime checks.

Successful output is:

```text
Configuration, credentials, and writable data paths are valid.
```

## Confirming live reload

After changing a setting or credentials, inspect service status and recent
logs:

```sh
docker compose ps
docker compose logs --since=2m mqtt-bridge
docker compose logs --since=2m ota-handler
docker compose logs --since=2m scanner-inspect
```

Depending on the change, look for messages such as:

```text
Applied updated configuration
Connected to local MQTT broker
Connected to remote MQTT broker
Listening for scanner keystrokes on the X11 desktop
```

The container creation time should remain unchanged during a normal live
reload. A broker outage can delay the connection message, but the configured
reconnect policy continues retrying automatically.

If someone manually writes invalid YAML or corrupts `credentials.enc`, running
services retain their last-known-good settings and log a rejected update. A
CLI `config set` operation validates before writing, so it normally cannot
produce an invalid runtime file.

## Settings not managed by `counterctl`

The following deployment settings live in `.env` and are consumed by Docker
Compose rather than the application configuration:

| Variable | Purpose | Default |
|---|---|---|
| `OTA_HTTP_PORT` | Host port mapped to the OTA HTTP service | `80` |
| `DISPLAY` | X11 display used by scanner capture | `:0` |
| `XAUTHORITY_DIR` | Host directory containing `Xauthority` | `/etc/counter-inspect/xauth` |
| `X11_HOSTNAME` | Hostname used to match local-family X11 cookies | `armbian` |

Changes to `.env` are not live-reloaded. Recreate the affected service:

```sh
docker compose up -d --force-recreate scanner-inspect
```

For an OTA HTTP port change, recreate `updates-http`:

```sh
docker compose up -d --force-recreate updates-http
```

MQTT topic names and payload contracts are defined in code and cannot be
changed with `counterctl`.

## Common workflows

### Change the device identity and remote broker

```sh
docker compose run --rm counterctl config set device_id HAS-AI-STB-02
docker compose run --rm counterctl config set brokers.remote.host mqtt.example.com
docker compose run --rm counterctl config set brokers.remote.port 1883
docker compose run --rm counterctl credentials set remote
docker compose run --rm counterctl config validate
docker compose logs --since=2m mqtt-bridge ota-handler scanner-inspect
```

No `docker compose restart` is required.

### Rotate both broker passwords

After changing the accounts on the brokers:

```sh
docker compose run --rm counterctl credentials set local
docker compose run --rm counterctl credentials set remote
docker compose run --rm counterctl config validate
```

### Temporarily enable debug logging

```sh
docker compose run --rm counterctl config set runtime.log_level DEBUG
docker compose logs -f mqtt-bridge ota-handler scanner-inspect
```

Restore normal logging afterward:

```sh
docker compose run --rm counterctl config set runtime.log_level INFO
```

### Tune scanner speed filtering

If valid scanner input is discarded, increase the timeout gradually:

```sh
docker compose run --rm counterctl config set scanner.char_timeout_seconds 0.3
```

If ordinary keyboard typing is being accepted as a scan, reduce it:

```sh
docker compose run --rm counterctl config set scanner.char_timeout_seconds 0.1
```

Watch the scanner logs while testing a real barcode:

```sh
docker compose logs -f scanner-inspect
```

## Troubleshooting

### `exec: "init": executable file not found`

The deployed Compose file is outdated and still defines `counterctl` with
`command:` instead of `entrypoint:`. Update `compose.yaml`; the current service
definition uses:

```yaml
entrypoint: ["python", "-m", "counter_inspect.cli"]
```

### Initialization says files already exist

Inspect the current installation first:

```sh
docker compose run --rm counterctl config show
docker compose run --rm counterctl config validate
```

Do not use `init --force` merely to change a device ID, host, port, or password.
Use `config set` or `credentials set` instead.

### A configuration key is unknown

Run `config show` and use the exact dotted path shown in the complete setting
reference. `config set` only changes existing scalar keys.

### A value has the wrong type

Ports and reconnect limits must be integers. Timeouts may be integers or
decimal numbers. Hosts, IDs, paths, URLs, and log levels must be strings.

Quote shell-sensitive values, particularly URLs containing `&`, `?`, spaces,
or wildcard characters. Note that OTA URLs containing query strings are
rejected even when correctly quoted.

### Credentials cannot be decrypted

The encryption key and `credentials.enc` do not match, the key is missing, or
the ciphertext is damaged. Restore both items from the same backup. Do not run
`init --force` unless discarding the old credential store is intentional.

### Services do not apply a change

Check:

```sh
docker compose ps
docker compose logs --since=5m mqtt-bridge ota-handler scanner-inspect
docker compose run --rm counterctl config validate
```

Look for a `Rejected configuration update` message. If the CLI reported a
successful update but containers are running an older image or Compose file,
verify that commands are being executed from the correct project directory.

### X11 scanner errors

`counterctl config validate` deliberately does not test X11. Check:

```sh
ls -ld /tmp/.X11-unix /etc/counter-inspect/xauth
ls -l /etc/counter-inspect/xauth/Xauthority
docker compose logs --tail=100 scanner-inspect
```

The recommended kiosk setup manages these files:

```sh
bash setup/setup-kiosk.sh http://192.168.100.38
```

Because the setup script also configures `eth0`, `eth1`, root autologin, and
the kiosk packages, review the main README before running it.

## Exit codes

| Exit code | Meaning |
|---:|---|
| `0` | Command completed successfully |
| `2` | Invalid arguments, configuration, credentials, or deployment validation |
| `130` | Interactive command cancelled with Ctrl+C |

Automation should treat every non-zero exit code as failure. Do not automate
password entry through command arguments or environment variables.

## Backup reminder

A recoverable credential backup requires both:

- `config/credentials.enc`
- The `master.key` file from the `counter-inspect_counter_secret_key` volume

Back up `config/runtime.yaml` at the same time. Protect the key separately from
the ciphertext whenever practical. See the main README's encryption-key backup
section for the exact Docker command.
