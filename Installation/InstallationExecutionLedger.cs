using System;
using System.IO;

namespace Libertix.Installation
{
    /// <summary>
    /// Persists legal installation transitions before another process or operating
    /// system is allowed to observe them.
    /// </summary>
    public sealed class InstallationExecutionLedger
    {
        private InstallationStateMachine _stateMachine;
        private string _mirrorPath;

        private InstallationExecutionLedger(
            string statePath,
            InstallationStateMachine stateMachine)
        {
            if (string.IsNullOrWhiteSpace(statePath))
                throw new ArgumentException("An execution state path is required.", nameof(statePath));

            StatePath = statePath;
            _stateMachine = stateMachine ?? throw new ArgumentNullException(nameof(stateMachine));
        }

        public string StatePath { get; }

        public InstallationExecutionState State => _stateMachine.State;

        public static InstallationExecutionLedger Create(string planId, string statePath)
        {
            var ledger = new InstallationExecutionLedger(
                statePath,
                InstallationStateMachine.Create(planId));
            ledger.Persist();
            return ledger;
        }

        public static InstallationExecutionLedger Open(string statePath)
        {
            return new InstallationExecutionLedger(
                statePath,
                new InstallationStateMachine(InstallationStateStore.Read(statePath)));
        }

        public void SetMirrorPath(string mirrorPath)
        {
            _mirrorPath = string.IsNullOrWhiteSpace(mirrorPath) ? null : mirrorPath;
        }

        public void StartStep(string step)
        {
            _stateMachine.StartStep(step);
            Persist();
        }

        public void CompleteStep(string step)
        {
            _stateMachine.CompleteStep(step);
            Persist();
        }

        public void RecordFailure(string code, string message, string component)
        {
            if (State.Status == InstallationStatus.RollbackRunning ||
                State.Status == InstallationStatus.RolledBack ||
                State.Status == InstallationStatus.Succeeded)
            {
                return;
            }

            _stateMachine.Fail(code, message, component);
            Persist();
        }

        public void BeginRollback()
        {
            if (State.Status != InstallationStatus.Running &&
                State.Status != InstallationStatus.Failed &&
                State.Status != InstallationStatus.Succeeded)
            {
                return;
            }

            _stateMachine.BeginRollback();
            Persist();
        }

        public void CompleteRollback()
        {
            Reload();
            if (State.Status == InstallationStatus.RolledBack)
                return;
            if (State.Status != InstallationStatus.RollbackRunning)
                throw new InvalidOperationException("Rollback proof is not in progress.");

            // Recovery records a compensation only after its postcondition is
            // verified. The state machine rejects every missing proof here.
            _stateMachine.CompleteRollback();
            Persist();
        }

        public void Reload()
        {
            if (!File.Exists(StatePath))
                return;

            _stateMachine = new InstallationStateMachine(
                InstallationStateStore.Read(StatePath));
        }

        public void Publish(string destinationPath)
        {
            InstallationStateStore.WriteAtomic(destinationPath, State);
        }

        private void Persist()
        {
            InstallationStateStore.WriteAtomic(StatePath, State);
            if (!string.IsNullOrWhiteSpace(_mirrorPath))
                InstallationStateStore.WriteAtomic(_mirrorPath, State);
        }
    }
}
