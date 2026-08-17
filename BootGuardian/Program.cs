using System;

namespace Libertix.BootGuardian
{
    internal static class Program
    {
        private static int Main(string[] args)
        {
            try
            {
                if (args.Length == 0)
                {
                    ServiceHost.Run();
                    return 0;
                }
                if (args.Length == 1 && args[0] == "--install-service")
                {
                    ServiceHost.Install(System.Reflection.Assembly.GetExecutingAssembly().Location);
                    return 0;
                }
                if (args.Length == 1 && args[0] == "--uninstall-service")
                {
                    ServiceHost.Uninstall();
                    return 0;
                }
                if (args.Length == 1 && args[0] == "--repair-now")
                {
                    return new BootGuardianEngine().Execute(
                        ServiceHost.ConfigPath,
                        TimeSpan.FromMinutes(1)) ? 0 : 2;
                }
                return 64;
            }
            catch (Exception error)
            {
                try { RepairJournal.WriteUncorrelatedError(error); }
                catch { }
                return 1;
            }
        }
    }
}
