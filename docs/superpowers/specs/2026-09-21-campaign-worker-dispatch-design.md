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
- No changes to the `OperationResult` model, artifact retention,
  `StreamEventProjector`, or `automation_operation_timeout_seconds`
  semantics. (The *contents* of `campaign_summary` list items change shape;
  see "Compatibility" below -- the Pydantic field itself does not.)
- No per-scenario process isolation / per-scenario hard-kill. The existing
  outer watchdog remains the only hard-kill boundary for this PR. A wedged
  scenario thread can still take down the whole campaign via that watchdog;
  a follow-up could add a supervisor model with per-child IPC if targeted
  kills turn out to be needed.
- No dispatcher-level auto-retry. Scenario runs are classified as
  passed/failed/retryable; re-running failed or retryable ones is a
  follow-up campaign call using the existing scenario-id filter.
- No new install-time capabilities (no new storage-fixture types, no new
  distros). `ScenarioSpec` must be able to represent everything
  `AutomationRequest`/`AutomationOptions` already support today, but the
  starter matrix stays close to current coverage.
- No dynamic VM cloning/deletion. Physical VMs remain statically configured
  in `Settings.vms`.
- No capability DSL. Compatibility between a scenario and a VM is one
  explicit predicate function, not a rules engine.

## Current foundation (upstream/dev)

- `automation_campaign.py`: `run_campaign()` loops over a fixed
  `SCENARIOS = (("mint","windows"), ("mint","linux"), ("zorin","windows"),
  ("zorin","linux"))`, and for each entry builds one `AutomationRequest`
  selecting all three configured VMs at once, calling back into
  `_run_operation` (a fresh `AutomationService` per call) through:
  `run_scenario: Callable[[AutomationRequest, Path, Callable[[StepResult],
  None]], OperationResult]`. Passes run sequentially; within a pass,
  `AutomationService.run()` already parallelizes across the selected VMs
  via `ThreadPoolExecutor`. Summary is written to `campaign-summary.json`
  after each pass via a single writer (safe today only because passes are
  sequential).
- `main.py`'s `_run_operation` (`main.py:151-198`) is where
  `AutomationCampaignRequest` is currently handled: it validates exactly
  three enabled VMs, then calls `run_campaign(request, vm_names,
  run_workspace, lambda child, workspace, publish: _run_operation(
  configured, "automation", child.selectors(), child, publish, workspace),
  on_step)`. For a plain `AutomationRequest`, the same `_run_operation`
  translates `request.snapshot_mode == "secondary-disk"` into the
  `secondary_snapshot` boolean and a swapped `reset_snapshot` Setting
  (`main.py:169-188`) before calling `AutomationService(...).run(...,
  secondary_snapshot=..., ...)`. This translation lives entirely inside
  `_run_operation` -- callers only ever set `snapshot_mode` on the request.
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
  followed by `self.validation.to_windows_share_path(...)`
  (`automation.py:188-189`) once per call, building/syncing against the
  shared build server and filepool over SSH, then converting the resulting
  `PurePosixPath` to the `PureWindowsPath` actually used by
  `_run_vm_isolated`. Calling `.run()` concurrently from independent
  scenario threads would race that shared build step.
- `AutomationService.run()` restores the clean snapshot baseline **at the
  start** of a call (`_restore_clean_snapshots`, `automation.py:178`,
  delegating to `AutomationPreflight.restore_clean_snapshot(s)` in
  `automation_preflight.py`), not at the end.

## Logical profiles, physical workers, and option ownership

**Logical profile vs. physical worker.** A profile is a `VMConfig.os`
string (e.g. `"Windows 10 UEFI"`). Multiple physical `VMConfig` entries can
share a profile (clones); they are interchangeable execution capacity for
any `ScenarioRun` targeting that profile. Cloning `win10-uefi-a` into
`win10-uefi-b` adds a second worker for the same one required
`mint/windows-first x Windows 10 UEFI` run -- it does not create a second,
distinct run.

**Compatibility predicate.** One explicit function, not a DSL:

```python
def _vm_compatible(vm: VMConfig, requirements: ScenarioRequirements) -> bool:
    if requirements.firmware is not None and vm.firmware != requirements.firmware:
        return False
    if requirements.requires_secondary_disk and not vm.secondary_disk_boot_order:
        return False
    return True
```

`vm.os` equality against a specific profile is applied separately (see
"Resolve" below); this predicate only covers firmware/secondary-disk-style
constraints, so a secondary-disk scenario can never be assigned to a VM
whose `os` string happens to match but which lacks the fixture.

**Required profiles for a spec** are computed against the **full configured
`automation_enabled` fleet** (`configured.vms`), not the filtered worker
pool:

```python
fleet_profiles(spec) = {vm.os for vm in all_automation_enabled_vms
                         if _vm_compatible(vm, spec.requirements)}
```

For the four nominal scenarios (`requirements = ScenarioRequirements()`,
no constraints), this is every configured profile -- the same full coverage
as today's fixed "exactly three VMs" campaign, expressed generically
instead of hardcoded to 3. Computing this from the *full* fleet (before any
`vms` filter is applied) is what lets "VM filter narrows the worker pool"
and "coverage can't silently drop" coexist: a filter can still be rejected
if it removes every worker for a profile the matrix actually requires.

**Option ownership.** `ScenarioSpec` owns only scenario-shaped fields, using
the **same field names and types `AutomationRequest` already uses** so the
translation at `_run_operation` never needs a second representation:
`distribution`, `first_boot`, `installation_target`, `snapshot_mode`,
`storage_fixture`, `boot_guardian_fault`, `simulate_stale_firmware_entries`,
`force_offline_ntfs_resize`, `share_windows_files_in_linux`,
`share_linux_files_in_windows`, `migrate_windows_preferences`,
`preference_wallpaper`, `verify_uninstall`. The campaign/request owns
`source`, `apply`, `linux_username`, `linux_password`, `linux_size_gib`, VM
selectors, and `continue_after_failure` -- exactly what
`AutomationCampaignRequest` already models today. The dispatcher builds
each child `AutomationRequest` by passing campaign-owned fields and one
spec's scenario-owned fields as separate, named keyword arguments into the
real `AutomationRequest` Pydantic model (not by merging dicts), so a
`ScenarioSpec` has no field through which it could set or override a
campaign-owned value, and the child request is validated exactly like a
hand-submitted one. `ScenarioSpec` therefore uses `snapshot_mode:
Literal["default", "secondary-disk"]`, not a `secondary_snapshot` boolean --
that boolean stays an internal derivation inside `_run_operation`
(`request.snapshot_mode == "secondary-disk"`), unchanged.

**`windows_path` is not a request field.** The shared prepared build path is
campaign-internal runtime state, produced once by the dispatcher and never
serialized into any `AutomationRequest`/`ScenarioSpec`. It is threaded
separately through the internal execution callback all the way to
`AutomationService.run(..., windows_path=...)` -- see "Build once" and the
"Worker loop" below.

## Data model

New module `auto_tests/app/services/campaign_dispatch.py`:

```python
@dataclass(frozen=True)
class ScenarioRequirements:
    firmware: Literal["bios", "uefi"] | None = None
    requires_secondary_disk: bool = False


@dataclass(frozen=True)
class ScenarioSpec:
    id: str
    tags: tuple[str, ...]
    requirements: ScenarioRequirements
    # Scenario-owned AutomationRequest/AutomationOptions fields only, same
    # names/types AutomationRequest already uses. Never source/apply/
    # credentials/VM selectors -- see "Option ownership".
    distribution: str = "mint"
    first_boot: Literal["windows", "linux"] = "windows"
    installation_target: Literal["windows", "secondary"] = "windows"
    snapshot_mode: Literal["default", "secondary-disk"] = "default"
    storage_fixture: StorageFixtureRequest | None = None
    boot_guardian_fault: str = "none"
    simulate_stale_firmware_entries: bool = False
    force_offline_ntfs_resize: bool = False
    share_windows_files_in_linux: bool = True
    share_linux_files_in_windows: bool = True
    migrate_windows_preferences: bool = False
    preference_wallpaper: Literal["custom", "windows-default"] = "custom"
    verify_uninstall: bool = False


ScenarioOutcome = Literal["passed", "failed", "retryable"]


@dataclass(frozen=True)
class ScenarioRun:
    run_id: str  # f"{scenario_id}::{profile}", stable across a resolve
    scenario_id: str
    profile: str  # VMConfig.os value this run must execute against


@dataclass
class ScenarioRunResult:
    run_id: str
    scenario_id: str
    profile: str
    vm: str
    outcome: ScenarioOutcome
    reason: str | None  # populated for failed/retryable/non-terminal states
    message: str
    errors: list[dict[str, object]]
    log: str
    captures: str
    claimed_at: str  # ISO timestamp
    finished_at: str
```

### Starter matrix

Preserves current coverage: the 4 existing nominal scenarios as
`ScenarioSpec(requirements=ScenarioRequirements())`, which (per the
"required profiles" rule above) expand to every configured profile -- the
same full coverage as today's fixed 3-VM campaign, generalized to however
many distinct profiles actually exist. One representative secondary-disk
`ScenarioSpec(requirements=ScenarioRequirements(requires_secondary_disk=True),
snapshot_mode="secondary-disk")` is included; it only produces
`ScenarioRun`s for profiles that actually have a VM with a non-empty
`secondary_disk_boot_order` in the current fleet -- if none exists, it
silently resolves to zero runs (a property of the matrix, not a dropped
filter; see "Resolve" for the distinction from an explicit `scenario_ids`
request for it). `boot_guardian_fault` scenarios stay out of the starter
matrix for this PR (single-VM-scoped; `ScenarioRequirements(firmware=...)`
already expresses their compatibility constraint for later additions).

## Dispatch algorithm

`CampaignDispatcher.run(request: AutomationCampaignRequest, matrix:
Sequence[ScenarioSpec], configured: Settings, on_step, run_workspace) ->
OperationResult` executes these steps in order:

1. **Resolve specs.** Apply `request.scenario_ids` against `matrix`
   (unknown id -> validation error; omitted -> full matrix). For each
   candidate spec, compute `fleet_profiles(spec)` from *every*
   `automation_enabled` VM in `configured.vms`. Drop specs with an empty
   `fleet_profiles(spec)` **unless** they were explicitly named in
   `scenario_ids` (explicit request for a scenario no VM in the fleet can
   ever run -> validation error naming the spec and why). Remaining specs
   = `resolved_specs`. If `resolved_specs` is empty -> validation error.
2. **Resolve physical worker pool.** Apply `request.vms`/`request.vm`
   against `configured.vms` (unknown VM name -> validation error; omitted
   -> every `automation_enabled` VM) -> `vm_pool`.
3. **Expand logical `ScenarioRun`s and validate profile coverage.** For
   each spec in `resolved_specs`, intersect `fleet_profiles(spec)` with
   `{vm.os for vm in vm_pool if _vm_compatible(vm, spec.requirements)}`.
   Any profile present in `fleet_profiles(spec)` but absent from that
   intersection -> validation error ("VM filter removes every worker for
   profile X required by scenario Y"). Otherwise emit one
   `ScenarioRun(run_id=f"{spec.id}::{profile}", ...)` per surviving
   profile. Zero total `ScenarioRun`s after this step -> validation error
   (should be unreachable given the per-spec check, kept as a final guard).
4. **`prepare_server()` once.** `ValidationService(configured).
   prepare_server(result, source=request.source)`, producing a
   `PurePosixPath`, before any worker thread starts.
5. **`to_windows_share_path()` once.** Convert that path via
   `ValidationService.to_windows_share_path(...)` into `windows_path:
   PureWindowsPath`. `AutomationService.run()` gains an optional
   `windows_path: PureWindowsPath | None = None` parameter; when set, it
   skips both step 4 and step 5's calls internally and uses the supplied
   path directly, exactly as it uses the locally computed `windows_path`
   today. `windows_path` is never placed on any `AutomationRequest` --
   it is threaded as a separate argument through the internal execution
   callback (see "Worker loop") straight into `_run_operation` ->
   `AutomationService.run(..., windows_path=windows_path)`. `_run_operation`
   gains a matching optional `windows_path` parameter, passed through only
   on the `"automation"` branch.
6. **Initialize and persist the full pending summary.** Build the `runs`
   list from every `ScenarioRun` produced in step 3, each with `status=
   "pending"`, and write it to `campaign-summary.json` (see schema below)
   together with the `requested`/`resolved` filter data, before any worker
   starts. The *set* of runs is fixed at this point and never changes.
7. **Create scheduler state, the persistence queue, and worker threads.**
   Two separate concurrency primitives, not one:
   - `SchedulerState`: an in-memory `pending: list[ScenarioRun]`
     (initialized from step 3/6), `quarantined: set[str]` (VM names), and
     `stop_claiming: bool`, all guarded by one `threading.Lock`
     (`scheduler_lock`). Workers touch this directly and synchronously --
     no I/O happens under `scheduler_lock`.
   - `updates: queue.Queue`: the only channel workers use to report state
     for persistence. **Workers never write `campaign-summary.json` and
     never mutate the in-memory summary directly** -- only the thread that
     called `CampaignDispatcher.run()` does that (see "Summary
     persistence").
   - One `threading.Thread` per VM in `vm_pool`, running the worker loop
     below.
8. **Worker loop** (per thread, for VM `vm`; the whole body is wrapped in
   `try/finally` so `("worker_done", vm.name)` is put on `updates`
   **exactly once, on every exit path** -- normal exhaustion, quarantine,
   `stop_claiming`, a construction error, or an unexpected exception from
   `run_scenario` itself):
   - **Atomic claim.** Under `scheduler_lock`: if `vm.name in quarantined`
     or `stop_claiming` is true, do nothing (fall through to exit). Else
     find the first entry in `pending` whose `profile == vm.os` and remove
     it from `pending` in the same critical section (so the quarantine
     check, the stop check, and the claim are one atomic transition -- no
     window where a worker claims after the stop condition became visible
     but before it observed it). If nothing compatible remains, exit
     (falls through to `finally`).
   - Release `scheduler_lock`, then report the claim and **wait for it to
     land on disk** before running anything: put `("claimed", run_id,
     vm.name, now, ack)` on `updates`, where `ack` is a `threading.Event`;
     block on `ack` before proceeding. This guarantees a hard kill after
     this point is recoverable as `interrupted`, never silently lost as
     `pending`.
   - Build the child `AutomationRequest` from campaign-owned fields (on
     `request`) plus the spec's scenario-owned fields (looked up by
     `scenario_id`), with `vms=[vm.name]`. `windows_path` is **not** part
     of this request.
   - Call `run_scenario(child_request, scenario_workspace, publish,
     windows_path)` -- the callback signature gains the `windows_path`
     parameter (today: `Callable[[AutomationRequest, Path, Callable[
     [StepResult], None]], OperationResult]`; new:
     `Callable[[AutomationRequest, Path, Callable[[StepResult], None],
     PureWindowsPath], OperationResult]`). The real implementation
     (wired in `main.py`, replacing today's campaign lambda) calls
     `_run_operation(configured, "automation", child.selectors(), child,
     publish, workspace, windows_path=windows_path)`, so each call gets a
     **fresh `AutomationService`** (no shared/pooled instance, so
     `self._capture_dir` mutation stays safe). `publish()` tags every step
     with `context={"scenario": scenario_id}` exactly as today, so
     `OperationProgress` stall detection needs no changes.
   - Classify the outcome (below). If it is `retryable` with `reason` in
     `{"restore_failed", "preflight_failed"}`, add `vm.name` to
     `quarantined` under `scheduler_lock`.
   - Put `("completed", ScenarioRunResult)` on `updates`.
   - Loop back to "Atomic claim".
   - `finally`: put `("worker_done", vm.name)` on `updates`, unconditionally.
9. **Dispatcher consumer loop** (the thread that called
   `CampaignDispatcher.run()`, running concurrently with the worker threads
   it started in step 7): loop on `updates.get()` until `worker_done` has
   been received from every started worker:
   - `"claimed"` -> set that run's entry to `running`, set `claimed_at`,
     persist, then set the handshake `Event` so the worker proceeds.
   - `"completed"` -> update the run's entry with its `ScenarioRunResult`,
     persist. If `outcome in {"failed", "retryable"}` and
     `request.continue_after_failure` is false, set `stop_claiming = True`
     under `scheduler_lock`.
   - `"worker_done"` -> decrement the active-worker count.
10. **Final sweep and aggregate result.** Once the active-worker count
    reaches 0, for every run still `pending`:
    - If no VM in `vm_pool` with a matching profile remains outside
      `quarantined` -> `status="no-compatible-worker-after-quarantine"`
      (it was never attempted because every eligible worker quarantined
      itself; not a `failed`/`retryable` outcome of its own).
    - Else if `stop_claiming` was set -> `status="stopped-after-failure"`.
    - (These two cases are exhaustive by construction -- a run cannot stay
      `pending` after every worker reports `worker_done` for any other
      reason. Treated as an internal-consistency bug, logged and swept as
      `"no-compatible-worker-after-quarantine"`, if it ever happens.)
    Persist the swept state, set `finished_at`, persist the final
    `campaign-summary.json`, and return one aggregated `OperationResult`:
    `status="ok"` only if every run's outcome is `"passed"`; otherwise
    `"error"` with a message summarizing counts (passed/failed/retryable/
    not-run). `campaign_summary` is the persisted `runs` list.

### Outcome classification

Conservative by construction -- a real failure can never be masked as
`retryable` just because a later, unrelated infra error also occurred:

- `run_scenario` raises -> caught, recorded as `automation.
  campaign_exception`, `outcome="failed"`. Exceptions always stay `failed`
  in v1; there is no structured signal today strong enough to trust an
  uncaught exception as "definitely infrastructure."
- `run_scenario` returns `status="error"` -> collect every error
  `StepResult.step` from `outcome.steps`. Define a small, explicit
  recognized-infra set (a starter heuristic, **not** a claim that every
  automation error is perfectly taxonomized yet):
  `{"automation.rollback_preflight", "automation.reset_vm_done",
  "automation.guest_network_ready", "automation.guest_network_discovery",
  "automation.guest_network_configure", "automation.guest_network_verify",
  "automation.vm_status"}`, plus any step starting with
  `"automation.rollback_"` (`automation_preflight.py`,
  `automation.py:815/855/860`).
  - If **every** error step for this run is in that recognized-infra set
    -> `outcome="retryable"`, `reason="restore_failed"` or
    `"preflight_failed"`.
  - If **any** error step is outside that set (a real Libertix/install/
    validation/workflow failure) -> `outcome="failed"`, even if infra
    errors are also present. One real failure anywhere in the run's error
    list is enough to keep it `failed`.
- `status == "ok"` but a selected VM lacks a successful `automation.
  vm_finished` verdict -> `automation.campaign_missing_verdict`,
  `outcome="failed"` (a workflow-shape bug, not infra -- matches today's
  behavior).
- Otherwise (no errors, successful terminal verdict) -> `outcome="passed"`.

No dispatcher-level auto-retry: both `failed` and `retryable` stop that run
from being retried automatically within the same campaign; a follow-up
campaign call with `scenario_ids` re-attempts either kind. This matches
issue #29's "actual Libertix validation failure -> failed... network/
Proxmox/harness interruption -> maybe retryable", applied per-run instead
of per-campaign. `continue_after_failure=false` stops new claims after
**either** `failed` or `retryable` (not failed alone); already-claimed
runs on other VMs still finish and get recorded.

### Restore-before-reuse

`AutomationService.run()` already restores the clean baseline **at the
start** of every call (`automation.py:178`), not at the end -- so a
worker's *next* claimed run already restores its own VM before doing
anything else; the common case needs no new code. The gap is only when
restore itself fails. In that case the affected run classifies as
`retryable` with `reason` in `{"restore_failed", "preflight_failed"}`
(above), and that worker is **quarantined**: it stops claiming further
runs for the rest of this campaign rather than immediately attempting
another run on a VM whose ability to reach a known baseline is now
unproven. No per-worker process killing and no automatic re-provisioning
in this PR -- quarantine only stops that one physical VM from consuming
further `ScenarioRun`s; any other VM sharing its profile keeps claiming
normally. If the quarantined VM was the only worker for some profile, that
profile's remaining `pending` runs are swept to
`"no-compatible-worker-after-quarantine"` at finish (see step 10) --
visible in `campaign-summary.json`, never silently dropped or reassigned,
and picked up by a follow-up campaign call.

### Summary persistence (concrete single-writer model)

Workers communicate exclusively through the `updates` queue described in
steps 7-9 above; **only the thread that called `CampaignDispatcher.run()`
ever reads or writes `campaign-summary.json` or the in-memory summary
dict** -- this makes "single writer" a literal property of the design, not
a claim about lock discipline. The separate `scheduler_lock` (step 7-8)
guards only the fast, in-memory claim/quarantine/stop-claiming state, never
disk I/O. `_persist_summary` keeps the existing atomic
`campaign-summary.json.tmp` -> `campaign-summary.json` replace, called
after every processed queue message (a claim, a completion, or the final
sweep), not just once per completed scenario, so a hard kill mid-campaign
leaves the on-disk file consistent with the last processed transition.

### `campaign-summary.json` schema

```json
{
  "format_version": 1,
  "requested": {"scenario_ids": null, "vms": null},
  "resolved": {
    "scenario_ids": ["mint-windows-first", "mint-linux-first",
                      "zorin-windows-first", "zorin-linux-first"],
    "vm_pool": ["win10-bios-a", "win10-uefi-a", "win10-uefi-b", "win11-uefi-a"]
  },
  "runs": [
    {
      "run_id": "mint-windows-first::Windows 10 UEFI",
      "scenario_id": "mint-windows-first",
      "profile": "Windows 10 UEFI",
      "vm": "win10-uefi-a",
      "status": "passed",
      "reason": null,
      "message": "...",
      "errors": [],
      "log": "...",
      "captures": "...",
      "claimed_at": "2026-09-21T03:14:00Z",
      "finished_at": "2026-09-21T04:02:11Z"
    }
  ],
  "counts": {
    "pending": 0, "running": 0, "passed": 10, "failed": 1,
    "retryable": 1, "interrupted": 0, "stopped_after_failure": 0,
    "no_compatible_worker_after_quarantine": 0
  },
  "started_at": "2026-09-21T03:00:00Z",
  "finished_at": "2026-09-21T04:05:00Z"
}
```

`format_version` (starting at `1`) is bumped whenever this schema changes,
so `read_interrupted_campaign_summary` validates against a known structure
instead of inventing another ad hoc heuristic later. `status` values:
`pending`, `running`, `passed`, `failed`, `retryable`, `interrupted`
(assigned only by the reader below, never written live by the dispatcher
itself), `stopped-after-failure`, `no-compatible-worker-after-quarantine`
(both assigned only by the dispatcher's step-10 finish sweep). `vm` is
`null` until claimed; `reason`, `message`, `errors`, `log`, `captures`,
`claimed_at`, `finished_at` are `null`/empty before a run is claimed.

### `read_interrupted_campaign_summary` (full rewrite)

Replaces the current `len(summary) != len(SCENARIOS)` check entirely --
that check cannot work once the run set is variable-length and filterable.

New validity check: `summary` must be a `dict` with `format_version == 1`,
containing `"runs"` (a list), `"resolved"`, and `"requested"`. Each item in
`"runs"` must be a `dict` containing at least `run_id`, `scenario_id`,
`profile`, `vm`, `status`. Anything else (wrong type, missing keys, unknown
`format_version`, oversized file) is treated as malformed and the function
returns an empty/absent result exactly as today -- fails safe, never
crashes the endpoint.

On a valid, interrupted (mid-campaign-crash) readback:
- Any run with `status == "running"` -> rewritten to `"interrupted"`.
- Any run with `status == "pending"` -> left as `"pending"` (distinguishable
  from `"interrupted"`: it was never claimed at all).
- Runs already `"passed"`, `"failed"`, `"retryable"`,
  `"stopped-after-failure"`, or `"no-compatible-worker-after-quarantine"`
  are left unchanged.
- `requested` filters, `resolved` pool/scenario ids, per-run `vm`
  assignment, and artifact paths (`log`/`captures`) are all preserved
  as-is from the file -- nothing is recomputed.

The reader projects the (possibly rewritten) `"runs"` list directly into
`OperationResult.campaign_summary`'s existing `list[dict[str, Any]]` shape
-- no change to `OperationResult` itself, and no separate legacy-shaped
projection unless the check in "Compatibility" below finds an existing
consumer that needs one.

### Compatibility with `/api/v1/automation/full[/stream]`

- **Request body:** `AutomationCampaignRequest` gains one new optional
  field, `scenario_ids: list[str] | None = None`. Existing callers that
  omit it are unaffected (full matrix, same as today). The existing
  `vms`/`vm` selectors (from `ValidationRequest`) change meaning from "must
  be exactly these 3 VMs" to "restrict the worker pool to these VMs" -- a
  deliberate relaxation of validation, not a request-shape change; a caller
  that always passed exactly 3 VM names keeps working unchanged.
- **Response body / `OperationResult.campaign_summary`:** stays the
  existing `list[dict[str, Any]]`-typed field, populated from the
  persisted `runs` list. **This is a genuine item-level shape change**,
  not purely additive: today's list has one entry per *scenario* with a
  `vms: {name: status}` sub-dict for all 3 VMs; the new list has one entry
  per (scenario, profile) *run*, each already pinned to a single `vm`
  string. A consumer reading `campaign_summary[i]["vms"][vmname]` today
  would need to change to filtering `campaign_summary` for entries
  matching a `vm`/`scenario_id`. Flagged explicitly rather than shipped
  silently -- confirm during planning whether any current caller/UI depends
  on the old per-scenario `vms` dict, and if so decide there whether to
  also emit a legacy-shaped projection.
- **Streaming events:** unchanged -- steps still flow through the same
  `on_step`/`StreamEventProjector` path with `context["scenario"]` set,
  since `OperationProgress` depends on that field already.

## API / wiring changes

- `AutomationService.run()`: add optional `windows_path: PureWindowsPath |
  None = None` (default `None`, existing behavior unchanged when omitted).
- `_run_operation` (`main.py`): add a matching optional `windows_path:
  PureWindowsPath | None = None` parameter, passed through only on the
  `"automation"` branch to `AutomationService(...).run(..., windows_path=
  windows_path)`.
- New module `auto_tests/app/services/campaign_dispatch.py`:
  `ScenarioRequirements`, `ScenarioSpec`, `ScenarioRun`, `ScenarioRunResult`,
  `CampaignDispatcher`, the starter matrix, `_vm_compatible`, the
  recognized-infra step set, and the persistence/schema helpers
  (`_persist_summary`, `read_interrupted_campaign_summary`, replacing the
  ones currently in `automation_campaign.py`).
- `automation_campaign.py`: `run_campaign` is replaced by
  `CampaignDispatcher` (confirm during planning whether any other
  caller/test still needs the old sequential entry point before deleting
  it, rather than keeping an unused compatibility shim).
- `main.py`: `_run_operation`'s `AutomationCampaignRequest` branch calls
  `CampaignDispatcher(...).run(...)` instead of `run_campaign(...)`; the
  campaign lambda gains the `windows_path` parameter (`lambda child,
  workspace, publish, windows_path: _run_operation(configured,
  "automation", child.selectors(), child, publish, workspace,
  windows_path=windows_path)`); same overall gating on
  `isinstance(request, AutomationCampaignRequest)`;
  `read_interrupted_campaign_summary` import moves to
  `campaign_dispatch.py`.
- `models.py`: `AutomationCampaignRequest` gains `scenario_ids: list[str] |
  None = None`. The `len(selected) != 3` VM-count check currently enforced
  for campaigns (`main.py:156-157`) is removed in favor of the dispatcher's
  own profile-coverage validation.

## Testing plan

Unit tests (no real Proxmox/SSH dependency, matching existing test style):

- Profile/coverage resolution: nominal scenarios expand to every configured
  profile; the secondary-disk scenario expands only to profiles with
  `secondary_disk_boot_order`; an explicitly-filtered scenario id with zero
  fleet-wide compatible profiles is a validation error; a VM filter that
  removes every worker for a still-required profile is a validation error;
  omitted filters resolve to the full starter matrix / full
  `automation_enabled` pool; a `scenario_ids` filter narrowing to zero
  resolved specs is a validation error.
- Claim-loop assignment: given a fake `run_scenario`, each worker only
  claims profile-compatible runs, no run is claimed twice, two VMs sharing
  a profile correctly compete for the same pending runs, a worker exits
  cleanly when nothing compatible remains.
- Atomic stop/claim race: a worker that checks `stop_claiming` and a
  concurrent `stop_claiming` write from the dispatcher consumer can never
  interleave such that a run is claimed after the stop condition became
  visible (exercised with a stub that forces the interleaving).
- `worker_done` guarantee: every exit path (exhaustion, quarantine,
  `stop_claiming`, a construction error, an exception from `run_scenario`)
  results in exactly one `("worker_done", vm.name)` reaching the consumer;
  the consumer loop always terminates.
- Outcome classification: exception (-> failed); error status with only
  recognized-infra error steps (-> retryable); error status with a mix of
  a real failure step and an infra step (-> failed, never masked);
  missing-verdict (-> failed); passed. Confirms a real failure is never
  reclassified as retryable just because an infra error also occurred.
- Restore-failure quarantine: a worker whose run classifies `retryable`
  with `reason="restore_failed"` stops claiming further runs; another VM
  sharing its profile keeps claiming.
- `continue_after_failure=false`: stops new claims after a `failed` **or**
  `retryable` outcome; in-flight runs on other VMs still complete and get
  recorded; untouched pending runs end up `stopped-after-failure`.
- Quarantine exhaustion: when every VM for a profile ends up quarantined,
  that profile's remaining pending runs are swept to
  `"no-compatible-worker-after-quarantine"`, not left `pending` or folded
  into `stopped-after-failure`.
- Summary persistence: the queue-driven single-writer path never
  interleaves/corrupts `campaign-summary.json` under concurrent worker
  completions; a `"running"` entry present at read time becomes
  `"interrupted"` while sibling `"pending"` entries stay `"pending"`;
  malformed files (bad `format_version`, missing keys, oversized) fail
  safe.
- `windows_path` plumbing: `AutomationService.run()` skips
  `prepare_server()`/`to_windows_share_path()` when given a `windows_path`;
  the dispatcher calls `prepare_server()`/`to_windows_share_path()` exactly
  once regardless of run count; `windows_path` never appears on any
  `AutomationRequest` instance.
- Option ownership: the child `AutomationRequest` built from a
  `ScenarioSpec` + campaign request contains exactly the expected merged
  fields (including `snapshot_mode` passed through unchanged to
  `_run_operation`'s existing `secondary_snapshot`/`reset_snapshot`
  translation), and no scenario-owned field can leak into or override a
  campaign-owned one (a `ScenarioSpec` has no field through which it could
  set `source`/`apply`/credentials).
