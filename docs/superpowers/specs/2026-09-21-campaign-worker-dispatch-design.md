# Campaign worker dispatcher design

Date: 2026-09-21
Branch: `feature/campaign-worker-dispatch` (cut from `upstream/dev`)
Related: ekimiateam/libertix issue #29

## Summary

`auto_tests` already runs one complete install-validate-restore scenario per
`AutomationRequest`, and `upstream/dev` already runs a fixed campaign of four
nominal scenarios (`mint`/`zorin` x `windows`/`linux`-first) sequentially
across the same three configured test VMs
(`auto_tests/app/services/automation_campaign.py`). As the scenario matrix
grows (secondary-disk installs, extra partitions, rollback/fault cases) and
VM profiles get cloned for more capacity, that sequential "one pass across
all VMs, then the next pass" model stops scaling: cloned VMs sit idle unless
the loop is manually restructured every time the matrix or VM count changes.

This spec replaces the sequential loop with a small in-process dispatcher
that treats **(scenario config x platform profile)** as the schedulable
unit, and lets any physical VM matching a profile pick up its next pending
unit independently. Cloning a VM adds execution capacity for its profile; it
never adds new required coverage.

## Non-goals

- No new operation type. This stays `operation="automation"`, exposed
  through the existing `AutomationCampaignRequest` /
  `/api/v1/automation/full[/stream]` endpoints, inside the existing
  `operation_lock` / `ActiveOperationProcess` / isolated-process boundary.
- No changes to `OperationResult`, artifact retention, `StreamEventProjector`,
  or `automation_operation_timeout_seconds` semantics.
- No per-scenario process isolation / per-scenario hard-kill. The existing
  outer watchdog remains the only hard-kill boundary for this PR. A wedged
  scenario thread can still take down the whole campaign via that watchdog;
  a follow-up could add a supervisor model with per-child IPC if targeted
  kills turn out to be needed.
- No scenario-level auto-retry. Scenarios are classified as passed/failed;
  re-running failed ones is a follow-up campaign call using the existing
  scenario-id filter.
- No new install-time capabilities (no new storage-fixture types, no new
  distros). `ScenarioSpec` must be able to represent everything
  `AutomationRequest`/`AutomationOptions` already support today, but the
  starter matrix stays close to current coverage.
- No dynamic VM cloning/deletion. Physical VMs remain statically configured
  in `Settings.vms`.

## Current foundation (upstream/dev)

- `automation_campaign.py`: `run_campaign()` loops over a fixed
  `SCENARIOS = (("mint","windows"), ("mint","linux"), ("zorin","windows"),
  ("zorin","linux"))`, and for each entry builds one `AutomationRequest`
  selecting all three configured VMs at once, calling back into
  `_run_operation` (a fresh `AutomationService` per call). Passes run
  sequentially; within a pass, `AutomationService.run()` already
  parallelizes across the selected VMs via `ThreadPoolExecutor`. Summary is
  written to `campaign-summary.json` after each pass via a single writer
  (safe today only because passes are sequential).
- `automation_progress.py`: `OperationProgress.observe()` tracks
  `active: dict[vm, last_progress_time]` keyed off step signatures that
  already include `context["scenario"]`. `main.py`'s
  `enforce_automation_timeout` uses `OperationProgress.oldest()` as a
  **per-VM inactivity/stall timeout** (`automation_operation_timeout_seconds`,
  default 1800s), not a total-runtime cap. This already applies to any
  `operation="automation"` call, campaigns included, and needs no changes.
- `VMConfig.os` (`config.py`) is already the platform-profile identity in
  practice, e.g. `"Windows 10 BIOS"`, `"Windows 10 UEFI"`, `"Windows 11
  UEFI"` in the example config. `VMConfig.firmware` and
  `VMConfig.secondary_disk_boot_order` are the other capability signals
  already present. No new capability DSL is needed.
- `AutomationService.run()` calls `self.validation.prepare_server(...)`
  once per call, building/syncing against the shared build server and
  filepool over SSH. Calling `.run()` concurrently from independent
  scenario threads would race that shared build step.

## Data model

New module `auto_tests/app/services/campaign_dispatch.py`:

```python
@dataclass(frozen=True)
class ScenarioSpec:
    id: str
    tags: tuple[str, ...]
    required_profiles: tuple[str, ...]  # VMConfig.os values this must run against
    options: dict[str, object]  # AutomationRequest/AutomationOptions-shaped kwargs

@dataclass(frozen=True)
class ScenarioRun:
    scenario_id: str
    profile: str
    options: dict[str, object]

@dataclass
class ScenarioRunResult:
    scenario_id: str
    profile: str
    vm: str
    status: Literal["ok", "error"]
    message: str
    errors: list[dict[str, object]]
    log: str
    captures: str
```

`ScenarioSpec.options` covers the full `AutomationRequest`-shaped surface
(`distribution`, `first_boot`, `installation_target`, `snapshot_mode`,
`storage_fixture`, `boot_guardian_fault`, etc.) so the dispatcher never
excludes scenarios that motivated it, even though the starter matrix only
populates a subset.

### Starter matrix

Preserves current coverage: the existing 4 nominal scenarios, each with
`required_profiles = (<all three configured profiles>,)`, expanding to the
same 12 `ScenarioRun`s as today's sequential campaign. One representative
secondary-disk/storage-fixture `ScenarioSpec` is added **only if** a
currently configured VM profile has a non-empty `secondary_disk_boot_order`
(checked at dispatch time, not hardcoded), targeting just that profile.
`boot_guardian_fault` scenarios are out of the starter matrix (they require
a single matching-firmware VM and existing scope validation in
`AutomationService.run()`), but `ScenarioSpec` supports them for later
additions.

## Dispatch algorithm

`CampaignDispatcher.run(request, resolved_specs, vm_pool, workspace,
run_scenario, on_step) -> OperationResult`:

1. **Resolve.** Expand `resolved_specs x required_profiles` into pending
   `ScenarioRun`s. Filters (`scenario_ids`, `vm names`) narrow only:
   unknown scenario id or VM name -> validation error. If narrowing leaves
   any required profile with zero matching physical VMs in `vm_pool`, that
   is also a validation error (coverage can't silently drop) rather than a
   silently smaller campaign.
2. **Build once.** Call `ValidationService(configured).prepare_server(result,
   source=request.source)` a single time before any scenario thread starts.
   `AutomationService.run()` gains an optional `prepared_executable:
   PureWindowsPath | None = None` parameter; when set, it skips its own
   `prepare_server()` call and uses the supplied path. All `ScenarioRun`s
   reuse this one build.
3. **Per-VM worker threads.** One `threading.Thread` per physical VM in the
   resolved pool. Each thread loops:
   - Under one `threading.Lock` guarding the pending-run list: pop the
     first unclaimed `ScenarioRun` whose `profile == vm.os`. If none, the
     thread exits.
   - Build a plain `AutomationRequest`-shaped call (single VM selector) and
     invoke `run_scenario(child_request, scenario_workspace, publish)`, the
     same callback shape `run_campaign` already uses, so each call gets
     a **fresh `AutomationService`** (no shared/pooled instance, so
     `self._capture_dir` mutation stays safe).
   - `publish()` tags every step with `context={"scenario": scenario_id}`
     exactly as today, so `OperationProgress` stall detection keeps working
     unmodified.
   - Classify the outcome (see below) and hand the `ScenarioRunResult` to
     the dispatcher (see "Summary persistence").
   - If `continue_after_failure` is false and any scenario has failed,
     stop claiming new runs (in-flight runs on other VMs still finish and
     get recorded). No hard-abort of in-flight work in this PR.
4. **Join** all worker threads, then return one aggregated `OperationResult`
   (`status="ok"` only if every claimed run passed) with `campaign_summary`
   populated from the collected `ScenarioRunResult`s, matching
   `OperationResult.campaign_summary`'s existing shape.

### Outcome classification

Reuses `run_campaign`'s existing approach rather than introducing a new
taxonomy:
- `run_scenario` raises -> caught, recorded as an `automation.
  campaign_exception` error step, `status="error"`.
- `run_scenario` returns `OperationResult.status == "error"` -> recorded as
  failed with its steps/errors.
- `status == "ok"` but a selected VM lacks a successful `automation.
  vm_finished` verdict -> `automation.campaign_missing_verdict` error,
  same as today.
- Otherwise -> passed.

No retryable/auto-retry classification in this PR (decided: classify via
existing ok/error shape; failures get re-run via a follow-up campaign call
with a scenario-id filter, not automatically).

### Summary persistence (thread safety)

Worker threads never call `_persist_summary` directly. Each worker reports
its `ScenarioRunResult` to the dispatcher through a single
`threading.Lock`-guarded summary structure; only the dispatcher thread
writes `campaign-summary.json.tmp` -> `campaign-summary.json` (same atomic
write-then-replace as today), once per completed scenario. This keeps
`read_interrupted_campaign_summary` valid for a mid-campaign crash while
making concurrent completions safe.

## API / wiring changes

- `AutomationService.run()`: add optional `prepared_executable` parameter
  (default `None`, existing behavior unchanged when omitted).
- `automation_campaign.py` (or a new `campaign_dispatch.py` alongside it):
  add `ScenarioSpec`, `ScenarioRun`, `CampaignDispatcher`, the starter
  matrix, and profile/pool resolution. `run_campaign` either becomes a thin
  wrapper delegating to `CampaignDispatcher`, or is replaced outright if
  nothing else depends on the old sequential entry point (confirm during
  planning by checking callers/tests).
- `main.py`: `_run_operation`'s `AutomationCampaignRequest` branch swaps its
  `run_campaign(...)` call for the new dispatcher, keeping the same
  `isinstance(request, AutomationCampaignRequest)` gating and the same
  `read_interrupted_campaign_summary` reuse on `publish_result`.
- `AutomationCampaignRequest` (`models.py`) gains optional `scenario_ids:
  list[str] | None` and narrows the existing VM selection
  (`ValidationRequest.vms`/`vm`) to mean "allowed worker pool" for the
  dispatcher rather than "exactly three VMs"; the `len(selected) != 3`
  check in `main.py` is replaced by the dispatcher's own
  profile-coverage validation.

## Testing plan

Unit tests (no real Proxmox/SSH dependency, matching existing test style):
- `ScenarioSpec` x profile expansion produces the expected `ScenarioRun`s.
- Filter resolution: unknown scenario id, unknown VM name, and "profile
  left with zero VMs after filtering" all raise a validation error;
  omitted filters resolve to the full starter matrix / full
  `automation_enabled` pool.
- Claim-loop assignment: given a fake `run_scenario` callable, each worker
  only claims profile-compatible runs, no run is claimed twice, a worker
  exits cleanly when nothing compatible remains, and `continue_after_failure
  =false` stops new claims after a failure while in-flight runs still
  complete and get recorded.
- Outcome classification: exception / error-status / missing-verdict /
  passed all map to the right recorded status, matching `run_campaign`'s
  current behavior.
- Summary persistence: concurrent `ScenarioRunResult` reports from multiple
  simulated workers never interleave/corrupt `campaign-summary.json`
  (single-writer invariant holds under concurrency).
- `prepared_executable` plumbing: `AutomationService.run()` skips
  `prepare_server()` when given a `prepared_executable`, and the dispatcher
  calls `prepare_server()` exactly once regardless of scenario count.
