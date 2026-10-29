using System.Text.RegularExpressions;

namespace Clicky.Services;

/// <summary>
/// Parses the trailing <c>[POINT:x,y:label:screenN]</c> / <c>[POINT:none]</c>
/// tag the AI appends to voice responses. Port of
/// <c>CompanionManager.parsePointingCoordinates</c>.
///
/// The orchestrator calls this after the stream completes to split the
/// reply into "spoken text" (TTS input) and the optional pointing target
/// (coordinate + screen + human-readable label).
/// </summary>
public static class PointingTagParser
{
    // Same regex the Swift app uses — groups:
    //   1 = x (integer pixels), 2 = y, 3 = label (optional), 4 = screen index (optional, 1-based)
    private static readonly Regex TrailingPointTagRegex = new(
        @"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    public static PointingParseResult Parse(string responseText)
    {
        if (string.IsNullOrEmpty(responseText))
        {
            return new PointingParseResult(string.Empty, null, null, null);
        }

        var match = TrailingPointTagRegex.Match(responseText);
        if (!match.Success)
        {
            return new PointingParseResult(responseText, null, null, null);
        }

        // The "spoken text" is everything before the tag, with trailing
        // whitespace trimmed — TTS should read the reply, not the tag.
        var spokenText = responseText.Substring(0, match.Index).TrimEnd();

        var hasCoordinate = match.Groups[1].Success && match.Groups[2].Success;
        if (!hasCoordinate)
        {
            // [POINT:none] — spoken text only, no flight.
            return new PointingParseResult(spokenText, null, "none", null);
        }

        var pointX = int.Parse(match.Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture);
        var pointY = int.Parse(match.Groups[2].Value, System.Globalization.CultureInfo.InvariantCulture);

        string? elementLabel = null;
        if (match.Groups[3].Success)
        {
            elementLabel = match.Groups[3].Value.Trim();
            if (elementLabel.Length == 0) elementLabel = null;
        }

        int? screenNumber = null;
        if (match.Groups[4].Success
            && int.TryParse(match.Groups[4].Value, System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out var parsedScreenNumber))
        {
            screenNumber = parsedScreenNumber;
        }

        return new PointingParseResult(spokenText, (pointX, pointY), elementLabel, screenNumber);
    }
}

/// <summary>
/// Result of parsing a <c>[POINT:…]</c> tag. <see cref="Coordinate"/> is
/// null when the AI emitted <c>[POINT:none]</c> (or no tag at all);
/// <see cref="ScreenNumber"/> is 1-based and references the cursor-first
/// capture list the AI saw, or null to default to the cursor screen.
/// </summary>
public sealed record PointingParseResult(
    string SpokenText,
    (int X, int Y)? Coordinate,
    string? ElementLabel,
    int? ScreenNumber);
