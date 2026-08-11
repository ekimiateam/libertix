using System.ComponentModel;

namespace Libertix.Models
{
    public class DistroInfo : DistroInfoJson, INotifyPropertyChanged
    {
        private bool _isSelected;

        public string IsoUrl { get; set; }

        public string IsoSha256 { get; set; }

        public string UefiIsoUrl { get; set; }

        public string UefiIsoSha256 { get; set; }

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
