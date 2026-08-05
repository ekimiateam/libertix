using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.RegularExpressions;

namespace Libertix.Installation
{
    /// <summary>
    /// Applies legal state transitions. Callers persist the returned snapshot
    /// immediately after each successful operation.
    /// </summary>
    public sealed class InstallationStateMachine
    {
        private static readonly Regex StepPattern = new Regex(
            "^(windows|live|target)\\.[a-z0-9]+(?:-[a-z0-9]+)*$",
            RegexOptions.CultureInvariant);
        private static readonly Regex ProgressStagePattern = new Regex(
            "^[a-z0-9]+(?:-[a-z0-9]+)*$",
            RegexOptions.CultureInvariant);

        private static readonly HashSet<string> KnownPhases = new HashSet<string>(StringComparer.Ordinal)
        {
            InstallationPhase.Windows,
            InstallationPhase.Live,
            InstallationPhase.Target
        };

        public InstallationStateMachine(InstallationExecutionState state)
        {
            State = state ?? throw new ArgumentNullException(nameof(state));
            ValidateState(state);
        }

        public InstallationExecutionState State { get; }

        public static InstallationStateMachine Create(string planId)
        {
            if (!IsHexId(planId))
                throw new ArgumentException("A 32-character lowercase hexadecimal planId is required.", nameof(planId));

            return new InstallationStateMachine(new InstallationExecutionState
            {
                PlanId = planId,
                Status = InstallationStatus.Pending,
                Phase = InstallationPhase.Windows,
                Progress = new InstallationProgress
                {
                    Stage = "initializing",
                    OverallPercent = 0
                },
                UpdatedAtUtc = DateTimeOffset.UtcNow
            });
        }

        public void SetProgress(string stage, int overallPercent, int? detailPercent = null)
        {
            if (string.IsNullOrWhiteSpace(stage) || !ProgressStagePattern.IsMatch(stage))
                throw new ArgumentException("A stable progress stage is required.", nameof(stage));
            if (overallPercent < 0 || overallPercent > 100)
                throw new ArgumentOutOfRangeException(nameof(overallPercent));
            if (detailPercent.HasValue && (detailPercent.Value < 0 || detailPercent.Value > 100))
                throw new ArgumentOutOfRangeException(nameof(detailPercent));

            State.Progress = new InstallationProgress
            {
                Stage = stage,
                OverallPercent = overallPercent,
                DetailPercent = detailPercent
            };
            Touch();
        }

        public void StartStep(string step)
        {
            // Validate the requested transition before mutating the in-memory
            // document. PowerShell and Python follow the same rule, and callers
            // must never observe a partially changed state after an exception.
            string phase = GetStepPhase(step);
            EnsureNotTerminal();
            if (State.Status == InstallationStatus.RollbackRunning)
                throw new InvalidOperationException("Installation steps cannot start during rollback.");
            if (!string.IsNullOrEmpty(State.ActiveStep))
                throw new InvalidOperationException($"Step '{State.ActiveStep}' is already active.");
            if (State.CompletedSteps.Contains(step, StringComparer.Ordinal))
                throw new InvalidOperationException($"Step '{step}' is already complete.");

            // A recovery retry may legitimately resume after a recorded failure.
            // Drop that failure here: without this, the ledger can reach
            // 'succeeded' while still carrying the diagnostics of a run that did
            // not succeed, and no later transition would ever clear it.
            if (State.Status == InstallationStatus.Failed)
                State.Failure = null;

            State.Phase = phase;
            State.ActiveStep = step;
            State.Status = InstallationStatus.Running;
            Touch();
        }

        public void CompleteStep(string step)
        {
            if (!string.Equals(State.Status, InstallationStatus.Running, StringComparison.Ordinal))
                throw new InvalidOperationException("Only a running installation can complete a step.");
            if (!string.Equals(State.ActiveStep, step, StringComparison.Ordinal))
                throw new InvalidOperationException($"Cannot complete '{step}'; active step is '{State.ActiveStep}'.");

            State.CompletedSteps.Add(step);
            State.ActiveStep = null;
            Touch();
        }

        public void Fail(string code, string message, string component)
        {
            EnsureNotTerminal();
            if (State.Status == InstallationStatus.RollbackRunning)
                throw new InvalidOperationException("Use rollback completion to report a rollback result.");
            if (string.IsNullOrWhiteSpace(code) || string.IsNullOrWhiteSpace(message))
                throw new ArgumentException("Failure code and message are required.");
            if (!IsFailureComponent(component))
                throw new ArgumentException("Unknown failure component.", nameof(component));

            State.Status = InstallationStatus.Failed;
            State.Failure = new InstallationFailure
            {
                Code = code,
                Message = message,
                Component = component
            };
            State.ActiveStep = null;
            Touch();
        }

        public void BeginRollback()
        {
            if (State.Status != InstallationStatus.Failed && State.Status != InstallationStatus.Running)
                throw new InvalidOperationException("Rollback can only begin from a running or failed installation.");

            State.Status = InstallationStatus.RollbackRunning;
            State.Phase = InstallationPhase.Rollback;
            State.ActiveStep = null;
            Touch();
        }

        public void CompleteCompensation(string completedStep)
        {
            if (State.Status != InstallationStatus.RollbackRunning)
                throw new InvalidOperationException("Compensations can only complete during rollback.");
            if (!State.CompletedSteps.Contains(completedStep, StringComparer.Ordinal))
                throw new InvalidOperationException($"Cannot compensate incomplete step '{completedStep}'.");
            if (State.CompensatedSteps.Contains(completedStep, StringComparer.Ordinal))
                return;

            State.CompensatedSteps.Add(completedStep);
            Touch();
        }

        public void CompleteRollback()
        {
            if (State.Status != InstallationStatus.RollbackRunning)
                throw new InvalidOperationException("No rollback is running.");

            State.Status = InstallationStatus.RolledBack;
            State.Phase = InstallationPhase.Complete;
            State.ActiveStep = null;
            Touch();
        }

        public void CompleteInstallation()
        {
            if (State.Status != InstallationStatus.Running || !string.IsNullOrEmpty(State.ActiveStep))
                throw new InvalidOperationException("Installation can complete only between successful steps.");

            State.Status = InstallationStatus.Succeeded;
            State.Phase = InstallationPhase.Complete;
            Touch();
        }

        public static void ValidateState(InstallationExecutionState state)
        {
            if (state == null)
                throw new ArgumentNullException(nameof(state));
            if (state.SchemaVersion != InstallationExecutionState.CurrentSchemaVersion)
                throw new InvalidOperationException("Unsupported installation execution state version.");
            if (!IsHexId(state.PlanId))
                throw new InvalidOperationException("Execution state has an invalid planId.");
            if (state.Revision < 0)
                throw new InvalidOperationException("Execution state revision cannot be negative.");
            if (!IsKnownStatus(state.Status))
                throw new InvalidOperationException("Execution state has an unknown status.");
            if (!IsKnownPhase(state.Phase))
                throw new InvalidOperationException("Execution state has an unknown phase.");
            if (state.UpdatedAtUtc == default(DateTimeOffset) ||
                state.UpdatedAtUtc.Offset != TimeSpan.Zero)
            {
                throw new InvalidOperationException("Execution state updatedAtUtc must be a valid UTC date-time.");
            }
            if (state.CompletedSteps == null || state.CompensatedSteps == null)
                throw new InvalidOperationException("Execution state step lists are required.");
            if (state.Progress != null &&
                (string.IsNullOrWhiteSpace(state.Progress.Stage) ||
                 !ProgressStagePattern.IsMatch(state.Progress.Stage) ||
                 state.Progress.OverallPercent < 0 ||
                 state.Progress.OverallPercent > 100 ||
                 (state.Progress.DetailPercent.HasValue &&
                  (state.Progress.DetailPercent.Value < 0 ||
                   state.Progress.DetailPercent.Value > 100))))
            {
                throw new InvalidOperationException("Execution state progress is invalid.");
            }
            if (state.CompletedSteps.Distinct(StringComparer.Ordinal).Count() != state.CompletedSteps.Count)
                throw new InvalidOperationException("Execution state contains duplicate completed steps.");
            if (state.CompensatedSteps.Distinct(StringComparer.Ordinal).Count() != state.CompensatedSteps.Count)
                throw new InvalidOperationException("Execution state contains duplicate compensated steps.");
            if (state.CompensatedSteps.Any(step => !state.CompletedSteps.Contains(step, StringComparer.Ordinal)))
                throw new InvalidOperationException("Execution state compensates an operation that never completed.");
            foreach (string step in state.CompletedSteps)
                GetStepPhase(step);
            if (!string.IsNullOrEmpty(state.ActiveStep))
                GetStepPhase(state.ActiveStep);
            if (state.Status == InstallationStatus.Failed && state.Failure == null)
                throw new InvalidOperationException("A failed execution state requires failure details.");
            if (state.Failure != null &&
                (string.IsNullOrWhiteSpace(state.Failure.Code) ||
                 string.IsNullOrWhiteSpace(state.Failure.Message) ||
                 !IsFailureComponent(state.Failure.Component)))
            {
                throw new InvalidOperationException("Execution state has invalid failure details.");
            }
            // Rollback states retain the originating failure as diagnostics.
            // Pending, running, and successful states cannot carry one because
            // it would describe an error that is not active in that lifecycle.
            if ((state.Status == InstallationStatus.Pending ||
                 state.Status == InstallationStatus.Running ||
                 state.Status == InstallationStatus.Succeeded) &&
                state.Failure != null)
            {
                throw new InvalidOperationException(
                    "Only failed and rollback execution states can carry failure details.");
            }
            if (state.Status == InstallationStatus.RollbackRunning && state.Phase != InstallationPhase.Rollback)
                throw new InvalidOperationException("A running rollback requires the rollback phase.");
            if ((state.Status == InstallationStatus.Succeeded || state.Status == InstallationStatus.RolledBack) &&
                state.Phase != InstallationPhase.Complete)
            {
                throw new InvalidOperationException("A terminal execution state requires the complete phase.");
            }
            if ((state.Status == InstallationStatus.Failed ||
                 state.Status == InstallationStatus.RollbackRunning ||
                 state.Status == InstallationStatus.Succeeded ||
                 state.Status == InstallationStatus.RolledBack) &&
                !string.IsNullOrEmpty(state.ActiveStep))
            {
                throw new InvalidOperationException("The current execution state cannot have an active step.");
            }
        }

        private static string GetStepPhase(string step)
        {
            if (string.IsNullOrWhiteSpace(step) || !StepPattern.IsMatch(step))
                throw new ArgumentException("An installation step is required.", nameof(step));

            int separator = step.IndexOf('.');
            string phase = separator > 0 ? step.Substring(0, separator) : string.Empty;
            if (!KnownPhases.Contains(phase))
                throw new ArgumentException($"Installation step '{step}' has an unknown phase.", nameof(step));
            return phase;
        }

        private static bool IsHexId(string value)
        {
            return !string.IsNullOrEmpty(value) && value.Length == 32 &&
                value.All(character =>
                    (character >= '0' && character <= '9') ||
                    (character >= 'a' && character <= 'f'));
        }

        private static bool IsFailureComponent(string component)
        {
            return component == InstallationPhase.Windows ||
                component == InstallationPhase.Live ||
                component == InstallationPhase.Target ||
                component == InstallationPhase.Rollback;
        }

        private static bool IsKnownPhase(string phase)
        {
            return KnownPhases.Contains(phase) ||
                phase == InstallationPhase.Rollback ||
                phase == InstallationPhase.Complete;
        }

        private static bool IsKnownStatus(string status)
        {
            return status == InstallationStatus.Pending ||
                status == InstallationStatus.Running ||
                status == InstallationStatus.Failed ||
                status == InstallationStatus.RollbackRunning ||
                status == InstallationStatus.RolledBack ||
                status == InstallationStatus.Succeeded;
        }

        private void EnsureNotTerminal()
        {
            if (State.Status == InstallationStatus.Succeeded || State.Status == InstallationStatus.RolledBack)
                throw new InvalidOperationException($"Installation is already terminal: {State.Status}.");
        }

        private void Touch()
        {
            checked
            {
                State.Revision++;
            }
            State.UpdatedAtUtc = DateTimeOffset.UtcNow;
        }
    }
}
