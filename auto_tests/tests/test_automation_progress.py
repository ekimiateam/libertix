from app.models import StepResult
from app.services.automation_progress import InstallationProgress, OperationProgress


def step(name: str, vm: str = "vm1", **context: object) -> StepResult:
    return StepResult(step=name, status="ok", message="observation", context={"vm": vm, **context})


def test_observation_changes_do_not_reset_the_progress_clock() -> None:
    progress = InstallationProgress()
    assert progress.observe("stage: 120-unsquashfs 45%")
    assert not progress.observe("12:41:01 stage: 120-unsquashfs 45% spinner /")
    assert progress.observe("stage: 120-unsquashfs 46%")
    assert not progress.observe("stage: 120-unsquashfs 45%")
    assert not progress.observe("stage: 120-unsquashfs 46%")
    assert progress.observe("stage: 130-target-system-config")
    assert not progress.observe("stage: 120-unsquashfs 46%")


def test_decreasing_encryption_and_separate_downloads_are_progress() -> None:
    progress = InstallationProgress()
    assert progress.observe("Waiting for decryption: 80% encrypted")
    assert progress.observe("Waiting for decryption: 70% encrypted")
    assert not progress.observe("Waiting for decryption: 80% encrypted")
    assert progress.observe("Downloading live.iso 100%")
    assert progress.observe("Downloading distro.iso 10%")
    assert progress.observe("Downloading distro.iso 11%")
    assert not progress.observe("Downloading distro.iso 10%")


def test_one_vm_cannot_keep_another_vm_alive() -> None:
    clock = OperationProgress(0)
    clock.observe(step("automation.vm_started"), 1)
    clock.observe(step("automation.vm_started", "vm2"), 1)
    clock.observe(step("automation.check_started", test="linux.grub"), 2)
    for now in range(3, 30):
        clock.observe(step("automation.check_started", "vm2", test=f"check-{now}"), now)
        clock.observe(step("automation.capture", label=f"frame-{now}"), now)
        assert clock.oldest() == ("vm1", 2)
    clock.observe(step("automation.vm_finished"), 30)
    assert clock.oldest() == ("vm2", 29)
    clock.observe(step("automation.vm_finished", "vm2"), 31)
    assert clock.oldest() == ("global", 31)


def test_repeated_progress_or_test_events_are_not_new_evidence() -> None:
    clock = OperationProgress(0)
    clock.observe(step("automation.vm_started"), 0)
    assert clock.observe(step("automation.monitor_installation", progress_generation=1), 1)
    assert not clock.observe(
        step("automation.monitor_installation", progress_generation=1, capture="new"), 2
    )
    assert not clock.observe(step("automation.monitor_installation", summary="looks different"), 3)
    assert clock.oldest() == ("vm1", 1)
    assert clock.observe(step("automation.monitor_installation", progress_generation=2), 4)
    assert clock.observe(step("automation.check_started", test="linux.root"), 5)
    assert not clock.observe(step("automation.check_started", test="linux.root", attempt=2), 6)
    assert clock.oldest() == ("vm1", 5)
