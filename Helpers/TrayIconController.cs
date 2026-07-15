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

        public TrayIconController(Action restoreWindow)
        {
            if (restoreWindow == null)
                throw new ArgumentNullException(nameof(restoreWindow));

            _icon = LoadLibertixIcon();
            _notifyIcon = new NotifyIcon
            {
                Icon = _icon,
                Text = "Libertix",
                Visible = false
            };
            _notifyIcon.DoubleClick += (_, __) => restoreWindow();

            var menu = new ContextMenuStrip();
            menu.Items.Add("Ouvrir Libertix", null, (_, __) => restoreWindow());
            _notifyIcon.ContextMenuStrip = menu;
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
                        "pack://application:,,,/Resources/Images/Icon.ico",
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
