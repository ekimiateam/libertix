using System;
using System.Drawing;
using System.Windows.Forms;

namespace Libertix.Helpers
{
    /// <summary>
    /// Owns the Windows notification-area icon used while an installation keeps
    /// running in the background. WPF does not provide a native tray icon.
    /// </summary>
    internal sealed class TrayIconController : IDisposable
    {
        private readonly Icon _icon;
        private readonly NotifyIcon _notifyIcon;
        private readonly ToolStripMenuItem _openMenuItem;

        public TrayIconController(Action restoreWindow, string openLabel)
        {
            if (restoreWindow == null)
                throw new ArgumentNullException(nameof(restoreWindow));
            if (string.IsNullOrWhiteSpace(openLabel))
                throw new ArgumentException("The tray menu label is required.", nameof(openLabel));

            _icon = LoadLibertixIcon();
            _notifyIcon = new NotifyIcon
            {
                Icon = _icon,
                Text = "Libertix",
                Visible = false
            };
            _notifyIcon.DoubleClick += (_, __) => restoreWindow();

            var menu = new ContextMenuStrip();
            _openMenuItem = new ToolStripMenuItem(openLabel, null, (_, __) => restoreWindow());
            menu.Items.Add(_openMenuItem);
            _notifyIcon.ContextMenuStrip = menu;
        }

        public void SetOpenLabel(string openLabel)
        {
            if (string.IsNullOrWhiteSpace(openLabel))
                throw new ArgumentException("The tray menu label is required.", nameof(openLabel));
            _openMenuItem.Text = openLabel;
        }

        public void Show(string title, string message)
        {
            _notifyIcon.Visible = true;
            _notifyIcon.BalloonTipTitle = title ?? "Libertix";
            _notifyIcon.BalloonTipText = message ?? string.Empty;
            _notifyIcon.BalloonTipIcon = ToolTipIcon.Info;
            _notifyIcon.ShowBalloonTip(8000);
        }

        public void Hide()
        {
            _notifyIcon.Visible = false;
        }

        public void Dispose()
        {
            _notifyIcon.Visible = false;
            _notifyIcon.ContextMenuStrip?.Dispose();
            _notifyIcon.Dispose();
            _icon.Dispose();
        }

        private static Icon LoadLibertixIcon()
        {
            try
            {
                var resource = System.Windows.Application.GetResourceStream(
                    new Uri(
                        "pack://application:,,,/Resources/Images/icon.ico",
                        UriKind.Absolute));
                if (resource?.Stream != null)
                {
                    using (resource.Stream)
                    using (var icon = new Icon(resource.Stream))
                        return (Icon)icon.Clone();
                }
            }
            catch
            {
                // Keep a usable tray icon if the packaged resource is damaged.
            }

            return (Icon)SystemIcons.Application.Clone();
        }
    }
}
