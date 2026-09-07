from __future__ import annotations

import argparse
from pathlib import Path

from .runtime import heartbeat_is_fresh


def main() -> int:
    parser = argparse.ArgumentParser(description="Check a Counter service heartbeat")
    parser.add_argument("path", type=Path)
    parser.add_argument("maximum_age_seconds", type=float)
    args = parser.parse_args()
    return 0 if heartbeat_is_fresh(args.path, args.maximum_age_seconds) else 1


if __name__ == "__main__":
    raise SystemExit(main())
