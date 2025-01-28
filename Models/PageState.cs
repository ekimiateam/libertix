using System;

namespace Libertix.Models
{
    public class PageState
    {
        public Type PageType { get; set; }
        public object State { get; set; }
        public string StateKey { get; set; }
    }
}