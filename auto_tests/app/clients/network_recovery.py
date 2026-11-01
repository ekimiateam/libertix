from __future__ import annotations

import shutil
import subprocess
import threading
import time
from collections.abc import Callable

from app.models import StepResult

# Installed only inside an isolated campaign worker, shared by its VM threads.
active: NetworkRecovery | None = None


class NetworkRecovery:
    def __init__(self, hosts: tuple[str, str], publish: Callable[[StepResult], None]) -> None:
        self.ping = shutil.which("ping")
        if self.ping is None:
            raise RuntimeError("Network recovery requires the ping executable")
        self.hosts = hosts
        self.publish = publish
        self.lock = threading.RLock()
        self.last_resumed_at = 0.0

    def checkpoint(self) -> None:
        # Do not start another remote operation while a VM thread waits for the network.
        with self.lock:
            pass

    def _probe(self) -> dict[str, bool]:
        reachable = {}
        for host in self.hosts:
            try:
                reachable[host] = (
                    subprocess.run(
                        [self.ping, "-n", "-c", "1", "-W", "1", host],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=3,
                        check=False,
                    ).returncode
                    == 0
                )
            except subprocess.TimeoutExpired:
                reachable[host] = False
        return reachable

    def recover(
        self,
        failed_at: float,
        *,
        replay_safe: bool = True,
        context: dict[str, object] | None = None,
    ) -> bool:
        with self.lock:
            if self.last_resumed_at > failed_at and replay_safe:
                return True
            reachable = self._probe()
            outage_started = time.monotonic() if not all(reachable.values()) else None
            if all(reachable.values()) and replay_safe:
                # A guest reboot or application error is not a lab-wide network outage.
                return False
            while not all(reachable.values()):
                elapsed = time.monotonic() - failed_at
                event_context = {
                    "reachable": reachable,
                    "outage_seconds": round(elapsed, 1),
                    **(context or {}),
                }
                self.publish(
                    StepResult(
                        step="automation.network.wait",
                        status="ok",
                        message="Waiting for both network probes; VM control is paused",
                        context=event_context,
                    )
                )
                time.sleep(5)
                reachable = self._probe()
            elapsed = time.monotonic() - failed_at
            prolonged_outage = (
                outage_started is not None and time.monotonic() - outage_started > 120
            )
            restart = not replay_safe or prolonged_outage
            if prolonged_outage:
                message = (
                    "Network restored after more than two minutes; restart the current scenario"
                )
            elif not replay_safe:
                message = (
                    "Network available but the remote command outcome is unknown; "
                    "restart the current scenario"
                )
            else:
                message = "Both network probes respond again; VM control can resume"
            event_context = {
                "reachable": reachable,
                "outage_seconds": round(elapsed, 1),
                "replay_safe": replay_safe,
                **(context or {}),
                "restart_reason": (
                    "prolonged_outage" if prolonged_outage else "unknown_command_outcome"
                )
                if restart
                else None,
            }
            self.publish(
                StepResult(
                    step=(
                        "automation.network.restart_required"
                        if restart
                        else "automation.network.resumed"
                    ),
                    status="ok",
                    message=message,
                    context=event_context,
                )
            )
            if restart:
                # The API supervisor stops every VM controller before releasing the run lock.
                threading.Event().wait()
            self.last_resumed_at = time.monotonic()
            return True


def checkpoint() -> None:
    if active is not None:
        active.checkpoint()


def recover(
    failed_at: float,
    *,
    replay_safe: bool = True,
    context: dict[str, object] | None = None,
) -> bool:
    return active is not None and active.recover(
        failed_at, replay_safe=replay_safe, context=context
    )
