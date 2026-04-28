using System.Globalization;
using System.Windows;
using System.Windows.Data;

namespace Clicky.Views;

/// <summary>
/// Collapses a UI element when its bound string is null, empty, or
/// whitespace; shows it otherwise. Used by the tray panel to hide the
/// transcript and response rows until they have content.
/// </summary>
[ValueConversion(typeof(string), typeof(Visibility))]
public sealed class StringToVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        return string.IsNullOrWhiteSpace(value as string) ? Visibility.Collapsed : Visibility.Visible;
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        throw new NotSupportedException();
    }
}
