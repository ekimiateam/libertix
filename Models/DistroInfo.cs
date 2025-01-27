using System;

namespace Libertix.Models
{
    public class DistroInfo
    {
        public string Name { get; set; }
        public string Description { get; set; }
        public string ImageUrl { get; set; }
        public string IsoUrl { get; set; }
        public double SizeInGB { get; set; }
    }
}
