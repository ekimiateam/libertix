using System;
using System.ComponentModel;

namespace Libertix.Models
{
    public class DistroInfo : INotifyPropertyChanged
    {
        public string Name { get; set; }
        public string Description { get; set; }
        public string ImageUrl { get; set; }
        public string IsoUrl { get; set; }
        public double SizeInGB { get; set; }

        private bool _isSelected;

        public bool IsSelected
        {
            get => _isSelected;
            set
            {
                _isSelected = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsSelected)));
            }
        }

        public event PropertyChangedEventHandler PropertyChanged;
    }
}
