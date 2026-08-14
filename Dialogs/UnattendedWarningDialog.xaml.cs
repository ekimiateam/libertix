using System;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Input;
using Libertix.Helpers;
using Libertix.Models;

namespace Libertix.Dialogs
{
    public partial class UnattendedWarningDialog : Window
    {
        private readonly TaskCompletionSource<bool> _decision =
            new TaskCompletionSource<bool>(
                TaskCreationOptions.RunContinuationsAsynchronously);

        private UnattendedWarningDialog()
        {
            InitializeComponent();
            Loaded += (_, __) =>
            {
                Activate();
                NoButton.Focus();
                Keyboard.Focus(NoButton);
            };
            Closed += (_, __) => _decision.TrySetResult(false);
        }

        public static async Task<bool> ShowAsync(
            Window owner,
            InstallationState state)
        {
            if (owner == null)
                throw new ArgumentNullException(nameof(owner));
            if (state == null)
                throw new ArgumentNullException(nameof(state));

            var dialog = new UnattendedWarningDialog()
            {
                Owner = owner
            };
            dialog.Show();
            try
            {
                const int maximumAttempts = 3;
                for (int attempt = 1; attempt <= maximumAttempts; attempt++)
                {
                    dialog.Activate();
                    dialog.NoButton.Focus();
                    Keyboard.Focus(dialog.NoButton);
                    Task acknowledgement =
                        UnattendedWorkflow.PublishStageAndWaitAsync(
                            "warning-ready",
                            timeoutSeconds: 45);
                    Task completed = await Task.WhenAny(
                        acknowledgement,
                        dialog._decision.Task);
                    if (completed == dialog._decision.Task)
                    {
                        bool accepted = await dialog._decision.Task;
                        if (!accepted)
                            return false;
                        await acknowledgement;
                        return true;
                    }

                    await acknowledgement;
                    completed = await Task.WhenAny(
                        dialog._decision.Task,
                        Task.Delay(TimeSpan.FromSeconds(3)));
                    if (completed == dialog._decision.Task)
                        return await dialog._decision.Task;
                }

                throw new InvalidOperationException(
                    "The unattended warning was not accepted after three keyboard attempts.");
            }
            finally
            {
                if (dialog.IsVisible)
                    dialog.Close();
            }
        }

        private void YesButton_Click(object sender, RoutedEventArgs e)
        {
            YesButton.IsEnabled = false;
            NoButton.IsEnabled = false;
            _decision.TrySetResult(true);
        }

        private void NoButton_Click(object sender, RoutedEventArgs e)
        {
            _decision.TrySetResult(false);
        }
    }
}
