from __future__ import annotations

import logging
import sys
from logging.handlers import TimedRotatingFileHandler
from pathlib import Path


def configure_logging(service_name: str, log_dir: Path, level_name: str) -> logging.Logger:
    logger = logging.getLogger(service_name)
    for handler in logger.handlers[:]:
        logger.removeHandler(handler)
        handler.close()
    logger.propagate = False
    logger.setLevel(getattr(logging, level_name.upper(), logging.INFO))
    formatter = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")

    stream = logging.StreamHandler(sys.stdout)
    stream.setFormatter(formatter)
    logger.addHandler(stream)

    try:
        service_dir = log_dir / service_name
        service_dir.mkdir(parents=True, exist_ok=True)
        file_handler = TimedRotatingFileHandler(
            service_dir / f"{service_name}.log",
            when="midnight",
            backupCount=14,
            encoding="utf-8",
        )
        file_handler.setFormatter(formatter)
        logger.addHandler(file_handler)
    except OSError as exc:
        logger.warning("Persistent file logging unavailable: %s", exc)
    return logger
