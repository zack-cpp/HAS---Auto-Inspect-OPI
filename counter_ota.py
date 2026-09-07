"""Compatibility entry point for the Dockerized OTA handler."""

from counter_inspect.ota import main


if __name__ == "__main__":
    raise SystemExit(main())
