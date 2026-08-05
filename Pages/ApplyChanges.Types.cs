using System.Net.Http;
using Libertix.Installation;

namespace Libertix.Pages
{
    public partial class ApplyChanges
    {
        private static readonly HttpClient SharedHttpClient = new HttpClient
        {
            Timeout = System.Threading.Timeout.InfiniteTimeSpan
        };

        private static bool GetFirmwareType(out FirmwareType firmwareType)
        {
            return FirmwareInterop.TryGetFirmwareType(out firmwareType);
        }
    }
}
