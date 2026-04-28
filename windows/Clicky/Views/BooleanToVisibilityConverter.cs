using System.Globalization;
using System.Windows;
using System.Windows.Data;

namespace Clicky.Views;

/// <summary>
/// Maps a bound boolean to <see cref="Visibility"/>. True → Visible,
/// False → Collapsed by default; pass <c>"Invert"</c> as the converter
/// parameter to flip the mapping (used by the tray panel to show the
/// welcome block while the main panel is collapsed, and vice-versa).
/// </summary>
[ValueConversion(typeof(bool), typeof(Visibility))]
public sealed class BooleanToVisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var boolValue = value is bool b && b;
        if (string.Equals(parameter as string, "Invert", StringComparison.OrdinalIgnoreCase))
        {
            boolValue = !boolValue;
        }
        return boolValue ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        throw new NotSupportedException();
    }
}
