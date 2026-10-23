namespace Libertix.Installation
{
    /// <summary>
    /// Screen that presents one installation run. The engine calls every member
    /// from any thread; implementations marshal to their own UI thread.
    /// </summary>
    internal interface IInstallationView
    {
        void AppendLog(string line);

        void ShowProgress(int percent, string step);

        /// <summary>Shows an enabled cancel action while running and hides it otherwise.</summary>
        void SetCancellationAvailable(bool available);

        void DisableCancellation();

        void SetRetryEnabled(bool enabled);

        /// <summary>Presents the restart action that completes a verified preparation.</summary>
        void ShowRebootAction();

        void HideRebootAction();

        void SetRebootEnabled(bool enabled);

        /// <summary>Blocks until the user acknowledges a result that needs manual action.</summary>
        void ShowBlockingMessage(string title, string message, bool isError);
    }
}
