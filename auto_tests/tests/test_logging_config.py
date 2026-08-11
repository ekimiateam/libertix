import logging
from logging.handlers import RotatingFileHandler

from app.logging_config import configure_logging


def test_reconfiguration_closes_the_previous_file_handler(tmp_path):
    root = logging.getLogger()
    original_handlers = root.handlers[:]
    original_level = root.level
    root.handlers.clear()

    try:
        configure_logging("INFO", tmp_path / "first")
        previous_file_handler = next(
            handler for handler in root.handlers if isinstance(handler, RotatingFileHandler)
        )

        configure_logging("INFO", tmp_path / "second")

        assert previous_file_handler.stream is None
    finally:
        for handler in root.handlers[:]:
            root.removeHandler(handler)
            handler.close()
        root.handlers.extend(original_handlers)
        root.setLevel(original_level)
