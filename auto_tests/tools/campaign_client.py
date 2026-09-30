"""Submit the complete campaign to the local auto-test API and follow its stream.

Run from the auto_tests directory: python -m tools.campaign_client --log LOG [--mode MODE]
"""

from __future__ import annotations

import argparse
import json
import secrets
import shutil
import string
import sys
import tomllib
import urllib.request
from pathlib import Path

from app.config import Settings
from app.services.automation_campaign import CampaignScenario, campaign_scenarios
from app.stream_events import StreamEventProjector

ROOT = Path(__file__).resolve().parents[1]
CONFIG_PATH = ROOT / "RUN" / "campaign.toml"
MODES = ("full", "clean2-only", "clean3-only")
EXPECTATION_LABELS = {
    "compatibility-refusal": "BIOS compatibility refusal",
    "install-uninstall": "installation and uninstall",
    "boot-order": "BootOrder repair",
    "preferred-path": "EFI replacement consent and repair",
    "preferred-path-rollback": "EFI replacement refusal and rollback",
}


def load_config(path: Path = CONFIG_PATH) -> dict[str, object]:
    with path.open("rb") as source:
        return tomllib.load(source)


def campaign_payload(config: dict[str, object], mode: str) -> dict[str, object]:
    return {
        "vms": list(config["vms"]),
        "source": "local",
        "apply": True,
        "linux_username": config["linux_username"],
        "linux_password": "".join(secrets.choice(string.ascii_lowercase) for _ in range(24)),
        "linux_size_gib": config["linux_size_gib"],
        "migrate_windows_preferences": False,
        "continue_after_failure": True,
        "include_nominal_scenarios": mode != "clean3-only",
        "include_storage_scenarios": mode != "clean2-only",
        "include_boot_guardian_scenarios": mode == "full",
        "include_local_filepool_scenarios": mode != "clean3-only",
        "retry_failed_scenarios": True,
    }


def payload_scenarios(payload: dict[str, object]) -> list[CampaignScenario]:
    return campaign_scenarios(
        nominal=bool(payload["include_nominal_scenarios"]),
        storage=bool(payload["include_storage_scenarios"]),
        boot_guardian=bool(payload["include_boot_guardian_scenarios"]),
        local_filepool=bool(payload["include_local_filepool_scenarios"]),
    )


def snapshot_mismatches(config: dict[str, object], mode: str, settings: Settings) -> list[str]:
    required = config.get("modes", {}).get(mode, {})
    return [
        f"--{mode} requires {name.upper()}={expected}; configured: {getattr(settings, name)}"
        for name, expected in required.items()
        if getattr(settings, name) != expected
    ]


def validate_success(
    data: dict[str, object],
    payload: dict[str, object],
    scenarios: list[CampaignScenario],
    firmwares: dict[str, str],
) -> None:
    """Reject a server success whose summary does not match the requested scenarios."""

    if data.get("status") != "ok":
        return
    names = [scenario.name for scenario in scenarios]
    start = payload.get("start_scenario")
    expected = names[names.index(start) :] if start else names
    items = data.get("campaign_summary")
    if (
        not isinstance(items, list)
        or not all(isinstance(item, dict) for item in items)
        or [item.get("scenario") for item in items] != names
    ):
        raise RuntimeError("Invalid campaign verdict: missing, duplicate, or unexpected scenarios.")
    for scenario, item in zip(scenarios, items, strict=True):
        required = "ok" if scenario.name in expected else "not-run"
        required_vms = scenario.vms(list(payload["vms"]), firmwares)
        cells = item.get("cells", {})
        if (
            not required_vms
            or item.get("status") != required
            or item.get("vms") != dict.fromkeys(required_vms, required)
            or not isinstance(cells, dict)
            or set(cells) != set(required_vms)
            or any(
                not isinstance(cell, dict) or cell.get("status") != required
                for cell in cells.values()
            )
        ):
            raise RuntimeError(
                "Invalid campaign verdict: inconsistent VM results for " + scenario.name
            )


def _bar(count: int, maximum: int) -> str:
    percent = 100 * count / maximum if maximum else 0
    filled = int(18 * percent / 100)
    return "[" + "#" * filled + "-" * (18 - filled) + f"] {percent:5.1f}%"


class CampaignProgress:
    """Count completed milestones from the event stream for the terminal footer."""

    def __init__(self, settings: Settings, vm_names: list[str]) -> None:
        self.settings = settings
        self.vm_names = vm_names
        self.labels = {vm.name: f"VM{vm.vmid}" for vm in settings.vms}
        self.milestones: dict[str, str] = {}
        self.scenarios: list[dict[str, object]] = []
        self.first_scenario_index = 1
        self.total_scenarios = 0
        self.completed: set[tuple[str, str, str]] = set()
        self.current: dict[str, str] = {}
        self.active: dict[str, dict[str, object]] = {}
        self.verdict: str | None = None

    def observe_step(self, data: dict[str, object]) -> None:
        step = data["step"]
        context = data.get("context", {})
        if step == "automation.campaign_retry":
            self.completed = {
                key
                for key in self.completed
                if not (
                    key[0] == context["scenario"]
                    and (not context.get("vm") or key[1] == context["vm"])
                )
            }
        if step == "automation.campaign_plan" and not self.scenarios:
            self.milestones = context["milestones"]
            self.scenarios = context["scenarios"]
            self.first_scenario_index = context.get("first_scenario_index", 1)
            self.total_scenarios = context.get("total_scenarios", len(self.scenarios))
        elif step == "automation.campaign_scenario":
            selected = next(item for item in self.scenarios if item["name"] == context["scenario"])
            for vm in [context["vm"]] if context.get("vm") else selected["vms"]:
                self.active[vm] = selected
                self.current[vm] = "preparing"

        vm = context.get("vm")
        if vm not in self.vm_names:
            return
        vm_failed = data["status"] == "error" or context.get("vm_status") == "error"
        stage = context.get("phase") or context.get("test") or step.removeprefix("automation.")
        self.current[vm] = ("ERROR: " if vm_failed else "") + str(stage)
        checkpoint = step
        if step.startswith("automation.test.") and "test" in context:
            checkpoint = "automation.test." + context["test"]
        eligible = self.active.get(vm, {}).get("vm_milestones", {}).get(vm, self.milestones)
        finished_ok = step != "automation.vm_finished" or context.get("vm_status") == "ok"
        if checkpoint in eligible and data["status"] == "ok" and finished_ok:
            self.completed.add((context["scenario"], vm, checkpoint))

    def _vm_milestones(self, item: dict[str, object], vm: str) -> dict[str, str]:
        return item.get("vm_milestones", {}).get(vm, self.milestones)

    def _scenario_line(self, vm: str, selected: dict[str, object]) -> str:
        snapshot = (
            self.settings.secondary_disk_reset_snapshot
            if selected["snapshot_mode"] == "secondary-disk"
            else self.settings.reset_snapshot
        )
        if selected.get("layout") == "local-filepool":
            configured = next(item for item in self.settings.vms if item.name == vm)
            snapshot = configured.local_filepool_snapshot or snapshot
        expectation = EXPECTATION_LABELS.get(
            selected.get("expectations", {}).get(vm), "installation and uninstall"
        )
        position = self.scenarios.index(selected) + self.first_scenario_index
        return (
            f"{self.labels.get(vm, vm)} · {position}/{self.total_scenarios} · "
            f"{selected['name']} · {snapshot} · {expectation}"
        )

    def print(self) -> None:
        if not self.scenarios:
            return
        total = sum(
            len(self._vm_milestones(item, vm)) for item in self.scenarios for vm in item["vms"]
        )
        done = len(self.completed)
        lines = [f"Campaign {_bar(done, total)} | {done}/{total} milestones completed"]
        for vm in self.vm_names:
            maximum = sum(
                len(self._vm_milestones(item, vm)) for item in self.scenarios if vm in item["vms"]
            )
            count = sum(key[1] == vm for key in self.completed)
            selected = self.active.get(vm)
            if selected:
                lines.append(self._scenario_line(vm, selected))
            label = self.labels.get(vm, vm)
            lines.append(f"{label} {_bar(count, maximum)} | {self.current.get(vm, 'waiting')}")
        if self.verdict:
            lines.append(f"Verdict: {self.verdict} — milestone completion, not elapsed time")
        print("PROGRESS " + json.dumps(lines, ensure_ascii=False), flush=True)


def stream_campaign(
    api_url: str,
    payload: dict[str, object],
    progress: CampaignProgress,
    scenarios: list[CampaignScenario],
    firmwares: dict[str, str],
) -> dict[str, object]:
    request = urllib.request.Request(
        api_url + "/api/v1/automation/full/stream?format=ndjson",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    terminal = None
    with urllib.request.urlopen(request, timeout=None) as response:
        for raw in response:
            event = json.loads(raw)
            if event.get("event") == "result":
                validate_success(event["data"], payload, scenarios, firmwares)
            print(StreamEventProjector.render(event, stream_format="compact"), end="", flush=True)
            if event["event"] == "result":
                terminal = event["data"]
            else:
                progress.observe_step(event["data"])
            progress.print()
    if terminal is None:
        raise RuntimeError(
            "The stream closed without a final verdict; no automatic retry was attempted."
        )
    return terminal


def archive_diagnostics(terminal: dict[str, object], log_path: Path) -> Path:
    """Copy failed-run evidence before later requests trigger server-side retention."""

    workspace = Path(terminal["detailed_log"]).parent
    archive = log_path.with_suffix(".diagnostics") / workspace.name
    archive.mkdir(parents=True, exist_ok=True)
    for manifest in workspace.rglob("manifest.json"):
        if "diagnostics" in manifest.relative_to(workspace).parts:
            shutil.copytree(manifest.parent, archive / manifest.parent.relative_to(workspace))
    evidence = [
        path
        for path in workspace.rglob("*.txt")
        if "diagnostics" not in path.relative_to(workspace).parts
    ]
    evidence += [
        workspace / "campaign-summary.json",
        workspace / "worker-fatal.log",
        workspace / "runtime-provenance.json",
        workspace / "release-provenance.json",
        *workspace.rglob("runtime-provenance.json"),
        *workspace.rglob("worker-fatal.log"),
        *workspace.glob("logs/api-runtime.txt.*"),
        *workspace.glob("captures/timeout-*.png"),
    ]
    for source in evidence:
        if source.is_file():
            destination = archive / source.relative_to(workspace)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination)
    return archive


def report_terminal(terminal: dict[str, object], log_path: Path) -> list[dict[str, object]]:
    for step in terminal.get("steps", []):
        if step["step"] == "automation.inactivity_timeout":
            print("ERROR " + json.dumps(step, ensure_ascii=False), flush=True)
    summaries = [
        item for item in terminal.get("campaign_summary", []) if item["status"] != "not-run"
    ]
    for item in summaries:
        item["service_log"] = terminal.get("detailed_log", "")
    had_retries = any(item.get("previous_attempts") for item in summaries)
    if (terminal["status"] != "ok" or had_retries) and terminal.get("detailed_log"):
        archive = archive_diagnostics(terminal, log_path)
        print(f"Diagnostics preserved: {archive}", flush=True)
        for item in summaries:
            item["diagnostics_archive"] = str(archive)
    return summaries


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--mode", choices=MODES, default="full")
    parser.add_argument("--step", default="")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_arguments(sys.argv[1:] if argv is None else argv)
    config = load_config()
    payload = campaign_payload(config, args.mode)
    scenarios = payload_scenarios(payload)
    names = [scenario.name for scenario in scenarios]
    if args.step and args.step not in names:
        print("Unknown scenario. Available choices: " + ", ".join(names), flush=True)
        return 2
    if args.step:
        payload["start_scenario"] = args.step
        print(
            f"Starting at {args.step}. "
            "Progress covers only this scenario and the remaining scenarios.",
            flush=True,
        )

    settings = Settings(_env_file=ROOT / ".env")
    mismatches = snapshot_mismatches(config, args.mode, settings)
    for mismatch in mismatches:
        print(mismatch, flush=True)
    if mismatches:
        return 2
    firmwares = {vm.name: vm.firmware for vm in settings.vms}
    progress = CampaignProgress(settings, list(payload["vms"]))
    api_url = str(config["api_url"])

    try:
        with urllib.request.urlopen(api_url + "/health", timeout=10) as response:
            if response.status != 200:
                raise RuntimeError("The automated-test server is not ready.")
        terminal = stream_campaign(api_url, payload, progress, scenarios, firmwares)
        summaries = report_terminal(terminal, args.log)
        failed = terminal["status"] != "ok" or any(item["status"] != "ok" for item in summaries)
        progress.verdict = "ERROR" if failed else "OK"
        for item in summaries:
            print("SUMMARY " + json.dumps(item, ensure_ascii=False), flush=True)
        summary_path = args.log.with_suffix(".summary.json")
        summary_path.write_text(
            json.dumps(
                {"status": progress.verdict, "scenarios": summaries}, ensure_ascii=False, indent=2
            ),
            encoding="utf-8",
        )
        print(f"Campaign summary and attempt lineage: {summary_path}", flush=True)
        progress.print()
        print("CAMPAIGN " + progress.verdict, flush=True)
        if failed:
            print(
                "FAILED: at least one scenario remains failed or interrupted; "
                "inspect the summary and diagnostics.",
                flush=True,
            )
            return 1
        return 0
    except KeyboardInterrupt:
        progress.verdict = "INTERRUPTED"
        progress.print()
        print(
            "Monitoring interrupted by Ctrl+C. The server campaign may still be running; "
            "check its state before restarting.",
            flush=True,
        )
        return 130
    except (OSError, ValueError, RuntimeError) as error:
        print(f"RUNNER FAILURE: {type(error).__name__}: {error}", flush=True)
        print(
            "The POST request was not retried automatically; "
            "check the server operation before trying again.",
            flush=True,
        )
        return 1


if __name__ == "__main__":
    sys.exit(main())
