using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Libertix.Support;

namespace Libertix.Controls
{
    public partial class SupportActions : UserControl
    {
        public static readonly DependencyProperty ContextProperty = DependencyProperty.Register(
            "Context", typeof(string), typeof(SupportActions), new PropertyMetadata("Libertix"));
        public static readonly DependencyProperty DetailsProperty = DependencyProperty.Register(
            "Details", typeof(string), typeof(SupportActions), new PropertyMetadata(string.Empty));

        public string Context { get => (string)GetValue(ContextProperty); set => SetValue(ContextProperty, value); }
        public string Details { get => (string)GetValue(DetailsProperty); set => SetValue(DetailsProperty, value); }

        public SupportActions()
        {
            InitializeComponent();
            Loaded += (sender, args) => { RefreshLabels(); Localization.LanguageChanged += LanguageChanged; };
            Unloaded += (sender, args) => Localization.LanguageChanged -= LanguageChanged;
        }

        private void LanguageChanged(object sender, EventArgs args) => RefreshLabels();

        private void RefreshLabels()
        {
            var labels = SupportReport.Labels(Localization.CurrentLanguage);
            CopyButton.Content = labels["copy"];
            IssueLinkText.Text = labels["issue"];
            StatusText.Text = labels["review"];
        }

        private async void Copy_Click(object sender, RoutedEventArgs args)
        {
            CopyButton.IsEnabled = false;
            string context = Context;
            string details = Details;
            try
            {
                string report = await Task.Run(() => SupportReport.Create(context, details));
                Clipboard.SetText(report);
                StatusText.Text = SupportReport.Labels(Localization.CurrentLanguage)["copied"];
            }
            catch (ExternalException error) { StatusText.Text = SupportReport.Labels(Localization.CurrentLanguage)["failed"] + " " + error.Message; }
            finally { CopyButton.IsEnabled = true; }
        }

        private void Issue_Click(object sender, RoutedEventArgs args)
        {
            try { SupportReport.OpenIssue(); }
            catch (Win32Exception error) { StatusText.Text = SupportReport.Labels(Localization.CurrentLanguage)["failed"] + " " + error.Message; }
            catch (InvalidOperationException error) { StatusText.Text = SupportReport.Labels(Localization.CurrentLanguage)["failed"] + " " + error.Message; }
        }
    }
}
