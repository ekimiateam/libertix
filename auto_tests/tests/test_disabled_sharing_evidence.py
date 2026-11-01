import subprocess

import pytest

from app.services.automation import AutomationService
from app.services.automation_types import AutomationOptions

from .test_core import settings


@pytest.mark.parametrize("mount_status", [0, 1, 2, 127])
@pytest.mark.parametrize("fstab_status", [0, 1, 2, 127])
def test_disabled_sharing_requires_both_absences_without_command_errors(mount_status, fstab_status):
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    checks = service._linux_checks(  # noqa: SLF001
        vm,
        AutomationOptions("test", "test-pass", True, share_windows_files_in_linux=False),
    )
    check = next(check for check in checks if check.name == "linux.windows_mount")
    stubs = f"findmnt() {{ return {mount_status}; }}; grep() {{ return {fstab_status}; }}; "
    result = subprocess.run(["sh", "-eu", "-c", stubs + check.command], capture_output=True)
    assert (result.returncode == 0) == (mount_status == 1 and fstab_status == 1)
