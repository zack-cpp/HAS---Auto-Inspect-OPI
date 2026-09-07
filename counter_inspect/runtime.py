from __future__ import annotations

import os
import signal
import threading
import time
from pathlib import Path
from typing import Callable


class Shutdown:
    def __init__(self) -> None:
        self.event = threading.Event()

    def install(self) -> None:
        def stop(_signum: int, _frame: object) -> None:
            self.event.set()

        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)


def touch_heartbeat(path: Path = Path("/tmp/counter-health")) -> None:
    path.touch(exist_ok=True)
    os.utime(path, None)


def service_loop(
    shutdown: Shutdown,
    interval: Callable[[], float],
    iteration: Callable[[], None],
) -> None:
    while not shutdown.event.is_set():
        iteration()
        touch_heartbeat()
        shutdown.event.wait(max(0.1, interval()))


def heartbeat_is_fresh(path: Path, maximum_age_seconds: float) -> bool:
    try:
        return time.time() - path.stat().st_mtime <= maximum_age_seconds
    except OSError:
        return False
