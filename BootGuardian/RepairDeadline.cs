using System;
using System.Diagnostics;

namespace Libertix.BootGuardian
{
    internal sealed class RepairDeadline
    {
        private readonly Stopwatch _clock = Stopwatch.StartNew();
        private readonly TimeSpan _timeout;

        internal RepairDeadline(TimeSpan timeout)
        {
            if (timeout <= TimeSpan.Zero)
                throw new ArgumentOutOfRangeException(nameof(timeout));
            _timeout = timeout;
        }

        internal int RemainingMilliseconds
        {
            get
            {
                TimeSpan remaining = _timeout - _clock.Elapsed;
                if (remaining <= TimeSpan.Zero)
                    return 0;
                return (int)Math.Min(int.MaxValue, Math.Ceiling(remaining.TotalMilliseconds));
            }
        }

        internal void ThrowIfExpired()
        {
            if (_clock.Elapsed >= _timeout)
                throw new TimeoutException("Boot guardian reached its preshutdown repair deadline.");
        }
    }
}
