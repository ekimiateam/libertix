using System;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace Libertix.Support
{
    public static class SupportReportDialog
    {
        public static void Show(string title, string message)
        {
            var labels = SupportReport.Labels(CultureInfo.CurrentUICulture.TwoLetterISOLanguageName);
            using (var dialog = new Form { Text = title, Width = 780, Height = 520,
                StartPosition = FormStartPosition.CenterScreen, MinimizeBox = false })
            {
                var details = new TextBox { Text = message, Multiline = true, ReadOnly = true,
                    ScrollBars = ScrollBars.Both, Dock = DockStyle.Fill };
                var actions = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 90,
                    AutoSize = true, FlowDirection = FlowDirection.LeftToRight };
                var status = new Label { AutoSize = true, Text = labels["review"] };
                var copy = new Button { Text = labels["copy"], AutoSize = true };
                var issue = new LinkLabel { Text = labels["issue"], AutoSize = true,
                    Margin = new Padding(8, 8, 8, 0) };
                var close = new Button { Text = labels["close"], AutoSize = true };
                copy.Click += (sender, args) =>
                {
                    try { Clipboard.SetText(SupportReport.Create(title, details.Text)); status.Text = labels["copied"]; }
                    catch (ExternalException error) { status.Text = labels["failed"] + " " + error.Message; }
                };
                issue.LinkClicked += (sender, args) =>
                {
                    try { SupportReport.OpenIssue(); }
                    catch (Win32Exception error) { status.Text = labels["failed"] + " " + error.Message; }
                    catch (InvalidOperationException error) { status.Text = labels["failed"] + " " + error.Message; }
                };
                close.Click += (sender, args) => dialog.Close();
                actions.Controls.AddRange(new Control[] { copy, issue, close, status });
                dialog.Controls.Add(details);
                dialog.Controls.Add(actions);
                dialog.AcceptButton = close;
                dialog.CancelButton = close;
                dialog.ShowDialog();
            }
        }
    }
}
