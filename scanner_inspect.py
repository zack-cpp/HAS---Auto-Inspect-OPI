"""Compatibility entry point for the Dockerized barcode scanner service."""

from counter_inspect.scanner import main


if __name__ == "__main__":
    raise SystemExit(main())
