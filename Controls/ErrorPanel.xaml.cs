using System.Windows;
using System.Windows.Controls;

namespace Libertix.Controls
{
    public partial class ErrorPanel : UserControl
    {
        public static readonly DependencyProperty TitleProperty =
            DependencyProperty.Register("Title", typeof(string), typeof(ErrorPanel), new PropertyMetadata(string.Empty));

        public static readonly DependencyProperty MessageProperty =
            DependencyProperty.Register("Message", typeof(string), typeof(ErrorPanel), new PropertyMetadata(string.Empty));

        public static readonly DependencyProperty DetailsProperty =
            DependencyProperty.Register("Details", typeof(string), typeof(ErrorPanel), new PropertyMetadata(string.Empty));

        public static readonly DependencyProperty AdditionalDetailsProperty =
            DependencyProperty.Register("AdditionalDetails", typeof(string), typeof(ErrorPanel), new PropertyMetadata(string.Empty));

        public string Title
        {
            get => (string)GetValue(TitleProperty);
            set => SetValue(TitleProperty, value);
        }

        public string Message
        {
            get => (string)GetValue(MessageProperty);
            set => SetValue(MessageProperty, value);
        }

        public string Details
        {
            get => (string)GetValue(DetailsProperty);
            set => SetValue(DetailsProperty, value);
        }

        public string AdditionalDetails
        {
            get => (string)GetValue(AdditionalDetailsProperty);
            set => SetValue(AdditionalDetailsProperty, value);
        }

        public ErrorPanel()
        {
            InitializeComponent();
        }

    }
}
