"""Exercise only the launcher's display process, without starting a campaign."""

import fcntl
import json
import os
import pty
import re
import select
import struct
import subprocess
import sys
import termios
import time
from pathlib import Path


def renderer_source():
    runner = Path(__file__).resolve().parents[1] / "RUN/run-test-auto.sh"
    return runner.read_text().split("} 2>&1 | python3 -u -c '\n", 1)[1].rsplit('\' "$LOG"', 1)[0]


def test_terminal_resize_redraws_logs_and_restores_input(tmp_path):
    master, slave = pty.openpty()
    original = termios.tcgetattr(slave)
    log = tmp_path / "display.log"

    def resize(rows, columns):
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))

    def read_until(marker):
        output = ""
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if select.select([master], [], [], 0.05)[0]:
                output += os.read(master, 65536).decode(errors="replace")
                plain = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", output)
                if marker in plain.replace("\r", "").replace("\n", ""):
                    return output
        raise AssertionError(f"Display did not emit {marker!r}: {output[-1000:]!r}")

    resize(30, 90)
    child_source = (
        "import fcntl, termios\nfcntl.ioctl(1, termios.TIOCSCTTY, 0)\n" + renderer_source()
    )
    process = subprocess.Popen(
        [sys.executable, "-u", "-c", child_source, str(log)],
        stdin=subprocess.PIPE,
        stdout=slave,
        stderr=slave,
        start_new_session=True,
    )
    try:
        status = ["Campaign [#####-----] 50.0% | testing", "VM501 [###-------] 30.0% | copying"]
        process.stdin.write(("PROGRESS " + json.dumps(status) + "\nLOG_MARKER\n").encode())
        process.stdin.flush()
        read_until("LOG_MARKER")
        flags = termios.tcgetattr(slave)[3]
        assert not flags & termios.ECHO
        assert flags & termios.ISIG
        for rows, columns in ((15, 42), (48, 130), (10, 25), (3, 10), (32, 90)):
            resize(rows, columns)
            # No new log input: the renderer must recover the existing line itself.
            read_until("LOG_MARKER")
            os.write(master, b"\n")
        process.stdin.write(b"FINAL_MARKER")
        process.stdin.close()
        read_until("FINAL_MARKER")
        assert process.wait(timeout=5) == 0
        assert termios.tcgetattr(slave) == original
        assert log.read_text() == "LOG_MARKER\nFINAL_MARKER" + "\n".join(status) + "\n"
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
        os.close(master)
        os.close(slave)


def test_redirected_logs_remain_plain_and_complete(tmp_path):
    log = tmp_path / "display.log"
    result = subprocess.run(
        [sys.executable, "-u", "-c", renderer_source(), str(log)],
        input="first line\nlast line",
        capture_output=True,
        text=True,
        timeout=10,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout == "first line\nlast line\n"
    assert log.read_text() == "first line\nlast line"
