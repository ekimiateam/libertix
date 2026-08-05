import logging
import sys
from logging.handlers import RotatingFileHandler
from pathlib import Path

from pythonjsonlogger.json import JsonFormatter


def configure_logging(level: str, log_dir: Path) -> None:
    formatter = JsonFormatter("%(asctime)s %(levelname)s %(name)s %(message)s %(step)s %(target)s")
    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setFormatter(formatter)

    log_dir.mkdir(parents=True, exist_ok=True)
    file_handler = RotatingFileHandler(
        log_dir / "api-runtime.txt",
        maxBytes=10 * 1024 * 1024,
        backupCount=5,
        encoding="utf-8",
    )
    file_handler.setFormatter(formatter)

    root = logging.getLogger()
    root.handlers.clear()
    root.addHandler(console_handler)
    root.addHandler(file_handler)
    root.setLevel(level.upper())
