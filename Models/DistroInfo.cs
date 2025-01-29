using System;
using System.ComponentModel;
using System.Windows;

namespace Libertix.Models
{
    public class DistroInfo : INotifyPropertyChanged
    {
        private bool _isSelected;
        private string _description;
        
        public string Name { get; set; }
        public string Description { get; set; }  // Changed to direct string instead of key
        public string ImageUrl { get; set; }
        public string IsoUrl { get; set; }
        public double SizeInGB { get; set; }
        
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
