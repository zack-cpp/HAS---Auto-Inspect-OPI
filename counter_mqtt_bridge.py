"""Compatibility entry point for the Dockerized MQTT bridge."""

from counter_inspect.bridge import main


if __name__ == "__main__":
    raise SystemExit(main())
