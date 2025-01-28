using System;
using System.ComponentModel;
using System.Windows;

namespace Libertix.Models
{
    public class DistroInfo : INotifyPropertyChanged
    {
        private bool _isSelected;
        private string _descriptionKey;
        
        public string Name { get; set; }
        public string DescriptionKey
        {
            get => _descriptionKey;
            set
            {
                _descriptionKey = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Description)));
            }
        }
        public string Description => (string)Application.Current.Resources[DescriptionKey];
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
