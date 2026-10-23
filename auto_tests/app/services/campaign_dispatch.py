from __future__ import annotations

import threading
from collections.abc import Sequence

from app.config import VMConfig
from app.models import OperationResult


def worker_profiles(vms: Sequence[VMConfig]) -> dict[str, str]:
    representatives: dict[tuple[str, str], str] = {}
    profiles = {}
    for vm in vms:
        profiles[vm.name] = representatives.setdefault((vm.os, vm.firmware), vm.name)
    return profiles


def preparation_failed(outcome: OperationResult) -> bool:
    if any(step.step == "automation.deploy" and step.status == "ok" for step in outcome.steps):
        return False
    errors = [
        step.step
        for step in outcome.steps
        if step.status == "error" and not step.step.startswith("automation.diagnostics.")
    ]
    preparation_steps = {
        "automation.rollback_preflight",
        "automation.reset_vm_done",
        "automation.guest_network_ready",
        "automation.guest_network_discovery",
        "automation.guest_network_configure",
        "automation.guest_network_verify",
        "automation.guest_interactive_session",
        "automation.vm_status",
        "automation.prepare_vm",
        "ssh.connect",
        "proxmox.rollback",
        "proxmox.check_snapshot",
        "proxmox.verify_rollback_snapshot",
        "proxmox.verify_rollback_status",
        "proxmox.start_vm",
        "proxmox.wait_task",
    }
    return bool(errors) and all(step in preparation_steps for step in errors)


class CampaignDispatcher:
    """Assign each required scenario/profile once; retries stay inside its existing runner."""

    def __init__(self, jobs: dict[tuple[int, str], set[str]]) -> None:
        self._pending = list(jobs)
        self._eligible = jobs
        self._running: dict[str, tuple[int, str]] = {}
        self._retired: set[str] = set()
        self._condition = threading.Condition()

    def claim(self, vm: str) -> tuple[int, str] | None:
        with self._condition:
            while vm not in self._retired:
                for job in self._pending:
                    if vm in self._eligible[job]:
                        self._pending.remove(job)
                        self._running[vm] = job
                        return job
                # A running peer can return a job after exhausting its preparation retries.
                if not any(vm in self._eligible[job] for job in self._running.values()):
                    return None
                self._condition.wait()
            return None

    def finish(self, vm: str, *, quarantine: bool = False) -> bool:
        with self._condition:
            job = self._running.pop(vm)
            reassigned = False
            if quarantine:
                self._retired.add(vm)
                if self._eligible[job] - self._retired:
                    self._pending.append(job)
                    reassigned = True
            self._condition.notify_all()
            return reassigned

    def retire(self, vm: str) -> None:
        with self._condition:
            self._retired.add(vm)
            self._running.pop(vm, None)
            self._condition.notify_all()
