using System.Windows;

namespace Libertix.Dialogs
{
    /// <summary>
    /// Displays confirmation actions in Libertix's selected language instead
    /// of inheriting button captions from the Windows display language.
    /// </summary>
    public partial class LocalizedConfirmationDialog : Window
    {
        private LocalizedConfirmationDialog(
            string title,
            string message,
            string yesCaption,
            string noCaption)
        {
            InitializeComponent();
            Title = title;
            MessageText.Text = message;
            YesButton.Content = yesCaption;
            NoButton.Content = noCaption;
        }

        public static bool Show(
            Window owner,
            string title,
            string message,
            string yesCaption,
            string noCaption)
        {
            var dialog = new LocalizedConfirmationDialog(
                title,
                message,
                yesCaption,
                noCaption)
            {
                Owner = owner
            };
            return dialog.ShowDialog() == true;
        }

        private void YesButton_Click(object sender, RoutedEventArgs e)
        {
            DialogResult = true;
        }

        private void NoButton_Click(object sender, RoutedEventArgs e)
        {
            DialogResult = false;
        }
    }
}
