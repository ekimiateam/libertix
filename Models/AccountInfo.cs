using System;

namespace Libertix.Models
{
    public class AccountInfo
    {
        public string Username { get; set; }
        public string Password { get; set; }
        public string ComputerName { get; set; }

        internal bool HasPassword => !string.IsNullOrEmpty(Password);

        internal void ClearPassword()
        {
            Password = null;
        }
    }
}
