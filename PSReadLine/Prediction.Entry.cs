/********************************************************************++

Copyright (c) Microsoft Corporation. All rights reserved.

--********************************************************************/

using System;
using System.Text;

namespace Microsoft.PowerShell
{
    public partial class PSConsoleReadLine
    {
        /// <summary>
        /// Represents a prediction source.
        /// </summary>
        private readonly struct SourceInfo
        {
            internal readonly string SourceName;
            internal readonly int EndIndex;
            internal readonly int PrevSourceEndIndex;
            internal readonly int ItemCount;

            internal SourceInfo(string sourceName, int endIndex, int prevSourceEndIndex)
            {
                SourceName = sourceName;

                int sourceWidth = LengthInBufferCells(SourceName);
                if (sourceWidth > PredictionListView.SourceMaxWidth)
                {
                    sourceWidth = PredictionListView.SourceMaxWidth - 1;
                    int sourceStrLen = SubstringLengthByCells(sourceName, sourceWidth);
                    SourceName = sourceName.Substring(0, sourceStrLen) + SuggestionEntry.Ellipsis;
                }

                EndIndex = endIndex;
                PrevSourceEndIndex = prevSourceEndIndex;
                ItemCount = EndIndex - PrevSourceEndIndex;
            }
        }

        /// <summary>
        /// This type represents an individual suggestion entry.
        /// </summary>
        private struct SuggestionEntry
        {
            internal const char Ellipsis = '\u2026';
            internal const string HistorySource = "History";

            // Use a private-use sentinel during width/truncation calculations so an embedded
            // newline occupies exactly one display cell. It is replaced with a bright glyph
            // only after layout has been calculated.
            private const char NewLineSentinel = '\uE000';
            private const char NewLineGlyph = '\u21B5'; // ↵

            internal readonly Guid PredictorId;
            internal readonly uint? PredictorSession;
            internal readonly string Source;
            internal readonly string ToolTip;
            internal readonly string SuggestionText;
            internal readonly int InputMatchIndex;
            internal readonly HistoryItem HistoryEntry;

            internal SuggestionEntry(string suggestion, int matchIndex)
                : this(suggestion, matchIndex, historyEntry: null)
            {
            }

            internal SuggestionEntry(string suggestion, int matchIndex, HistoryItem historyEntry)
                : this(
                    source: HistorySource,
                    predictorId: Guid.Empty,
                    predictorSession: null,
                    suggestion: suggestion,
                    tooltip: null,
                    matchIndex: matchIndex,
                    historyEntry: historyEntry)
            {
            }

            internal SuggestionEntry(
                string source,
                Guid predictorId,
                uint? predictorSession,
                string suggestion,
                string tooltip,
                int matchIndex,
                HistoryItem historyEntry = null)
            {
                Source = source;
                PredictorId = predictorId;
                PredictorSession = predictorSession;
                SuggestionText = suggestion;
                ToolTip = tooltip;
                InputMatchIndex = matchIndex;
                HistoryEntry = historyEntry;
            }

            /// <summary>
            /// Convert CR, LF, or CRLF to a single-cell sentinel and translate the match index
            /// from the original command into the flattened display string.
            /// </summary>
            private static string FlattenForDisplay(string text, int matchIndex, out int displayMatchIndex)
            {
                if (text.IndexOfAny(new[] { '\r', '\n' }) is -1)
                {
                    displayMatchIndex = matchIndex;
                    return text;
                }

                var display = new StringBuilder(text.Length);
                displayMatchIndex = matchIndex < 0 ? -1 : 0;

                for (int i = 0; i < text.Length; i++)
                {
                    if (i == matchIndex)
                    {
                        displayMatchIndex = display.Length;
                    }

                    char ch = text[i];
                    if (ch == '\r')
                    {
                        if (i + 1 < text.Length && text[i + 1] == '\n')
                        {
                            i++;
                        }

                        display.Append(NewLineSentinel);
                    }
                    else if (ch == '\n')
                    {
                        display.Append(NewLineSentinel);
                    }
                    else
                    {
                        display.Append(ch);
                    }
                }

                if (matchIndex == text.Length)
                {
                    displayMatchIndex = display.Length;
                }

                return display.ToString();
            }

            /// <summary>
            /// Append one display range, rendering flattened newline sentinels as a bright glyph.
            /// </summary>
            private static void AppendDisplayRange(
                StringBuilder line,
                string text,
                int start,
                int length,
                object style,
                string selectionHighlighting,
                string newlineStyle)
            {
                if (length <= 0)
                {
                    return;
                }

                int end = start + length;
                int current = start;

                if (style is not null)
                {
                    line.Append(style);
                }

                while (current < end)
                {
                    int newline = text.IndexOf(NewLineSentinel, current, end - current);
                    if (newline < 0)
                    {
                        line.Append(text, current, end - current);
                        break;
                    }

                    if (newline > current)
                    {
                        line.Append(text, current, newline - current);
                    }

                    if (style is not null)
                    {
                        line.EndColorSection(selectionHighlighting);
                    }

                    line.Append(newlineStyle)
                        .Append(NewLineGlyph)
                        .EndColorSection(selectionHighlighting);

                    if (style is not null)
                    {
                        line.Append(style);
                    }

                    current = newline + 1;
                }

                if (style is not null)
                {
                    line.EndColorSection(selectionHighlighting);
                }
            }

            /// <summary>
            /// Append a slice of display text while preserving highlighting for the user-input match.
            /// </summary>
            private static void AppendDisplaySlice(
                StringBuilder line,
                string displayText,
                int start,
                int length,
                int matchIndex,
                int matchLength,
                string selectionHighlighting,
                string newlineStyle)
            {
                int end = start + length;
                int matchEnd = matchIndex < 0 ? -1 : matchIndex + matchLength;

                if (matchIndex < 0 || matchEnd <= start || matchIndex >= end)
                {
                    AppendDisplayRange(
                        line,
                        displayText,
                        start,
                        length,
                        null,
                        selectionHighlighting,
                        newlineStyle);
                    return;
                }

                int highlightStart = Math.Max(start, matchIndex);
                int highlightEnd = Math.Min(end, matchEnd);

                AppendDisplayRange(
                    line,
                    displayText,
                    start,
                    highlightStart - start,
                    null,
                    selectionHighlighting,
                    newlineStyle);

                AppendDisplayRange(
                    line,
                    displayText,
                    highlightStart,
                    highlightEnd - highlightStart,
                    _singleton._options.EmphasisColor,
                    selectionHighlighting,
                    newlineStyle);

                AppendDisplayRange(
                    line,
                    displayText,
                    highlightEnd,
                    end - highlightEnd,
                    null,
                    selectionHighlighting,
                    newlineStyle);
            }

            /// <summary>
            /// Choose a single-line slice that keeps the input match visible when truncation is required.
            /// </summary>
            private static (int Start, int Length, bool LeadingEllipsis, bool TrailingEllipsis) GetDisplayWindow(
                string text,
                int matchIndex,
                int matchLength,
                int width)
            {
                int totalWidth = LengthInBufferCells(text);
                if (totalWidth <= width)
                {
                    return (0, text.Length, false, false);
                }

                if (width <= 1)
                {
                    int length = SubstringLengthByCells(text, 1);
                    return (0, length, false, length < text.Length);
                }

                if (matchIndex <= 0)
                {
                    int length = SubstringLengthByCells(text, width - 1);
                    return (0, length, false, length < text.Length);
                }

                int matchEnd = Math.Min(text.Length, matchIndex + matchLength);
                int matchWidth = LengthInBufferCells(text, matchIndex, matchEnd);

                bool mayClipLeft = matchIndex > 0;
                bool mayClipRight = matchEnd < text.Length;
                int ellipsisWidth = (mayClipLeft ? 1 : 0) + (mayClipRight ? 1 : 0);
                int contentWidth = Math.Max(1, width - ellipsisWidth);

                if (matchWidth >= contentWidth)
                {
                    int length = SubstringLengthByCells(text, matchIndex, contentWidth);
                    int end = matchIndex + length;
                    return (matchIndex, length, mayClipLeft, end < text.Length);
                }

                int contextWidth = contentWidth - matchWidth;
                int leftBudget = contextWidth / 2;
                int rightBudget = contextWidth - leftBudget;

                int leftLength = leftBudget > 0
                    ? SubstringLengthByCellsFromEnd(text, matchIndex - 1, leftBudget)
                    : 0;

                int rightLength = rightBudget > 0 && matchEnd < text.Length
                    ? SubstringLengthByCells(text, matchEnd, rightBudget)
                    : 0;

                int start = matchIndex - leftLength;
                int endIndex = matchEnd + rightLength;

                // If one side had less text than its budget, spend the unused cells on the other side.
                int usedWidth = LengthInBufferCells(text, start, endIndex);
                int spareWidth = contentWidth - usedWidth;
                if (spareWidth > 0 && start > 0)
                {
                    int extraLeft = SubstringLengthByCellsFromEnd(text, start - 1, spareWidth);
                    start -= extraLeft;
                    spareWidth -= LengthInBufferCells(text, start, start + extraLeft);
                }

                if (spareWidth > 0 && endIndex < text.Length)
                {
                    int extraRight = SubstringLengthByCells(text, endIndex, spareWidth);
                    endIndex += extraRight;
                }

                return (
                    start,
                    endIndex - start,
                    LeadingEllipsis: start > 0,
                    TrailingEllipsis: endIndex < text.Length);
            }

            /// <summary>
            /// Generate the list item text to be rendered for the list view.
            /// </summary>
            /// <remarks>
            /// The list item text is rendered in this form:
            ///
            ///   &gt; LENGTH │ ---------------- ITEM TEXT ---------------- [SOURCE]
            ///
            /// Multiline commands remain unchanged in the actual suggestion text but are flattened
            /// to one physical display row, with each logical newline shown as a bright '↵'.
            /// </remarks>
            /// <param name="width">The width of the list item.</param>
            /// <param name="input">The user input.</param>
            /// <param name="selectionHighlighting">The highlighting sequence for a selected list item.</param>
            /// <param name="commandLengthWidth">Width of the aligned command-length field.</param>
            internal string GetListItemText(
                int width,
                string input,
                string selectionHighlighting,
                int commandLengthWidth)
            {
                const int ellipsisLength = 1;

                string textMetadataColor = _singleton._options._listPredictionColor;
                string newlineStyle = textMetadataColor + "\x1b[1m";

                string displayText = FlattenForDisplay(
                    SuggestionText,
                    InputMatchIndex,
                    out int displayMatchIndex);

                string commandLength = SuggestionText.Length.ToString();
                commandLengthWidth = Math.Max(commandLengthWidth, commandLength.Length);

                // Calculate the SOURCE portion to be rendered.
                int sourceStrLen = Source.Length;
                int sourceWidth = LengthInBufferCells(Source);
                if (sourceWidth > PredictionListView.SourceMaxWidth)
                {
                    sourceWidth = PredictionListView.SourceMaxWidth;
                    sourceStrLen = SubstringLengthByCells(Source, sourceWidth - ellipsisLength);
                }

                // Decorations are:
                //   "> " + LENGTH + " │ " + ITEM + " [" + SOURCE + "]"
                // which consumes 8 cells in addition to the length and source fields.
                int textWidth = Math.Max(1, width - commandLengthWidth - sourceWidth - 8);

                var line = new StringBuilder(capacity: width + 32)
                    .Append(selectionHighlighting)
                    .Append(textMetadataColor)
                    .Append('>')
                    .EndColorSection(selectionHighlighting)
                    .Append(' ')
                    .Append(textMetadataColor)
                    .Append(' ', commandLengthWidth - commandLength.Length)
                    .Append(commandLength)
                    .Append(" │")
                    .EndColorSection(selectionHighlighting)
                    .Append(' ');

                bool isMultiline = displayText.IndexOf(NewLineSentinel) >= 0;

                var window = GetDisplayWindow(
                    displayText,
                    isMultiline ? 0 : displayMatchIndex,
                    isMultiline ? 0 : input.Length,
                    textWidth);

                if (window.LeadingEllipsis)
                {
                    line.Append(Ellipsis);
                }

                AppendDisplaySlice(
                    line,
                    displayText,
                    window.Start,
                    window.Length,
                    displayMatchIndex,
                    input.Length,
                    selectionHighlighting,
                    newlineStyle);

                if (window.TrailingEllipsis)
                {
                    line.Append(Ellipsis);
                }

                int renderedTextWidth = LengthInBufferCells(
                    displayText,
                    window.Start,
                    window.Start + window.Length)
                    + (window.LeadingEllipsis ? 1 : 0)
                    + (window.TrailingEllipsis ? 1 : 0);

                if (renderedTextWidth < textWidth)
                {
                    line.Append(Spaces(textWidth - renderedTextWidth));
                }

                line.Append(' ')
                    .Append('[')
                    .Append(textMetadataColor);

                if (sourceStrLen == Source.Length)
                {
                    line.Append(Source);
                }
                else
                {
                    line.Append(Source, 0, sourceStrLen)
                        .Append(Ellipsis);
                }

                line.EndColorSection(selectionHighlighting)
                    .Append(']');

                if (selectionHighlighting is not null)
                {
                    line.Append(VTColorUtils.AnsiReset);
                }

                return line.ToString();
            }
        }
    }
}
