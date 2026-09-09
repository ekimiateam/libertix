import json

import pytest

from app.clients.ssh import CommandResult
from app.errors import WorkflowError
from app.services.automation import AutomationService
from app.services.common import ResultBuilder
from tests.test_core import settings


@pytest.mark.parametrize("secondary_restored", [True, False])
def test_rollback_cannot_pass_with_only_the_system_disk_restored(monkeypatch, secondary_restored):
    service = AutomationService(settings())
    baseline = {
        "SYSTEM_DISK_NUMBER": "0",
        "SYSTEM_PARTITION_NUMBER": "3",
        "SYSTEM_PARTITION_OFFSET": "1048576",
        "SYSTEM_PARTITION_SIZE": "64424509440",
        "PARTITION_LAYOUT_JSON": "[]",
        "EXECUTION_PLAN_IDS_JSON": "[]",
        "STORAGE_LAYOUT_JSON": '[{"Number":0},{"Number":1}]',
    }
    received = {}

    def check(*args, **kwargs):
        received.update(kwargs["config"])
        return CommandResult(
            "ROLLBACK_VERIFIED=True\nROLLBACK_LEDGER_VERIFIED=True\n"
            "ROLLBACK_PARTITION_LAYOUT_MATCHES=True\nROLLBACK_BOOT_GUARDIAN_PRESENT=False\n"
            f"ROLLBACK_STORAGE_LAYOUT_MATCHES={secondary_restored}\nRESULT=OK",
            "",
            0,
        )

    monkeypatch.setattr(service, "_run_windows_script_resiliently", check)
    result = ResultBuilder("automation")
    arguments = (None, service.settings.vms[0], baseline, result)
    if secondary_restored:
        service._verify_exact_windows_rollback(*arguments, step="test", failure_message="failed")
        assert result.success("done").status == "ok"
    else:
        with pytest.raises(WorkflowError, match="failed"):
            service._verify_exact_windows_rollback(
                *arguments, step="test", failure_message="failed"
            )
    assert received["storage_layout"] == json.loads(baseline["STORAGE_LAYOUT_JSON"])


@pytest.mark.parametrize("files_preserved", [True, False])
def test_rollback_also_requires_fixture_hashes_and_redirected_documents(
    monkeypatch, files_preserved
):
    service = AutomationService(settings())
    baseline = {
        "SYSTEM_DISK_NUMBER": "0",
        "SYSTEM_PARTITION_NUMBER": "3",
        "SYSTEM_PARTITION_OFFSET": "1048576",
        "SYSTEM_PARTITION_SIZE": "64424509440",
        "PARTITION_LAYOUT_JSON": "[]",
        "EXECUTION_PLAN_IDS_JSON": "[]",
        "STORAGE_LAYOUT_JSON": '[{"Number":0},{"Number":1}]',
    }
    receipt = {"user_documents": {"files": ["witness"]}, "witnesses": ["fat32-witness"]}
    calls, documents = [], []

    def run(*args, **kwargs):
        calls.append(kwargs)
        if kwargs["script_name"] == "verify_installation_rollback.ps1":
            output = (
                "ROLLBACK_VERIFIED=True\nROLLBACK_LEDGER_VERIFIED=True\n"
                "ROLLBACK_PARTITION_LAYOUT_MATCHES=True\nROLLBACK_BOOT_GUARDIAN_PRESENT=False\n"
                "ROLLBACK_STORAGE_LAYOUT_MATCHES=True\nRESULT=OK"
            )
        else:
            assert kwargs["script_name"] == "storage_fixture.ps1"
            assert kwargs["config"] == {"phase": "verify", "receipt": receipt}
            output = f"STORAGE_FIXTURE_VERIFIED={files_preserved}"
        return CommandResult(output, "", 0)

    monkeypatch.setattr(service, "_run_windows_script_resiliently", run)
    monkeypatch.setattr(
        service, "_verify_storage_documents_fixture", lambda *args: documents.append(args[2])
    )
    arguments = (None, service.settings.vms[0], baseline, ResultBuilder("automation"))
    keywords = {"step": "test", "failure_message": "failed", "storage_fixture_receipt": receipt}
    if files_preserved:
        service._verify_exact_windows_rollback(*arguments, **keywords)
        assert documents == [receipt["user_documents"]]
    else:
        with pytest.raises(WorkflowError, match="Storage fixture preservation"):
            service._verify_exact_windows_rollback(*arguments, **keywords)
        assert not documents
    assert len(calls) == 2
