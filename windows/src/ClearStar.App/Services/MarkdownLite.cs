using System.Diagnostics;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;

namespace ClearStar.App.Services;

/// <summary>
/// Renders the small Markdown subset used by the legal texts (headings, paragraphs, bullet and numbered
/// lists, pipe tables, bold/italic/code/links) into a WPF FlowDocument. Soft line breaks inside a paragraph
/// are joined, so hard-wrapped source files flow with the window width.
/// </summary>
public static class MarkdownLite
{
    public static FlowDocument ToDocument(string markdown, Brush text, Brush muted, Brush accent, Brush rule, FontFamily body)
    {
        var doc = new FlowDocument { FontFamily = body, FontSize = 12.5, Foreground = text, PagePadding = new Thickness(0), TextAlignment = TextAlignment.Left };
        var lines = markdown.Replace("\r\n", "\n").Split('\n');
        var para = new List<string>();
        List? list = null;

        void FlushParagraph()
        {
            if (para.Count == 0) return;
            var p = new Paragraph { Margin = new Thickness(0, 0, 0, 10) };
            AddInlines(p.Inlines, string.Join(" ", para), accent);
            doc.Blocks.Add(p);
            para.Clear();
        }
        void FlushList() { if (list is not null) { doc.Blocks.Add(list); list = null; } }

        for (int i = 0; i < lines.Length; i++)
        {
            string line = lines[i].TrimEnd();
            if (line.Length == 0) { FlushParagraph(); FlushList(); continue; }

            var heading = Regex.Match(line, @"^(#{1,6})\s+(.*)$");
            if (heading.Success)
            {
                FlushParagraph(); FlushList();
                int level = heading.Groups[1].Value.Length;
                var p = new Paragraph { FontWeight = FontWeights.SemiBold, FontSize = level <= 1 ? 17 : level == 2 ? 15 : 13.5, Margin = new Thickness(0, level <= 2 ? 14 : 10, 0, 6) };
                AddInlines(p.Inlines, heading.Groups[2].Value, accent);
                doc.Blocks.Add(p);
                continue;
            }
            if (Regex.IsMatch(line, @"^(-{3,}|\*{3,})$"))
            {
                FlushParagraph(); FlushList();
                doc.Blocks.Add(new BlockUIContainer(new System.Windows.Controls.Border { Height = 1, Background = rule, Margin = new Thickness(0, 6, 0, 10) }));
                continue;
            }
            if (line.StartsWith('|'))
            {
                FlushParagraph(); FlushList();
                var rows = new List<string[]>();
                while (i < lines.Length && lines[i].TrimEnd().StartsWith('|'))
                {
                    string row = lines[i].Trim();
                    if (!Regex.IsMatch(row, @"^\|[\s:|-]+\|$")) rows.Add(SplitRow(row));
                    i++;
                }
                i--;
                doc.Blocks.Add(BuildTable(rows, text, muted, accent, rule));
                continue;
            }
            var bullet = Regex.Match(line, @"^\s*([*+-]|\d+[.)])\s+(.*)$");
            if (bullet.Success)
            {
                FlushParagraph();
                bool numbered = char.IsDigit(bullet.Groups[1].Value[0]);
                var marker = numbered ? TextMarkerStyle.Decimal : TextMarkerStyle.Disc;
                if (list is null || list.MarkerStyle != marker) { FlushList(); list = new List { MarkerStyle = marker, Margin = new Thickness(8, 0, 0, 10), Padding = new Thickness(16, 0, 0, 0) }; }
                var p = new Paragraph { Margin = new Thickness(0, 0, 0, 4) };
                AddInlines(p.Inlines, bullet.Groups[2].Value, accent);
                list.ListItems.Add(new ListItem(p));
                continue;
            }
            // Continuation of a list item (indented text) or an ordinary paragraph line.
            if (list is not null && lines[i].StartsWith("  ") && list.ListItems.LastListItem?.Blocks.LastBlock is Paragraph lp)
            {
                lp.Inlines.Add(new Run(" "));
                AddInlines(lp.Inlines, line.Trim(), accent);
                continue;
            }
            FlushList();
            para.Add(line.Trim());
        }
        FlushParagraph(); FlushList();
        return doc;
    }

    /// <summary>
    /// A hard-wrapped plain-text licence (the GPL text) as a flowing document: centred lines become
    /// headings, "  1. Title." lines section titles, lettered clauses hanging-indent items, deeper
    /// indented blocks stay preformatted, everything else is joined into wrapped paragraphs.
    /// </summary>
    public static FlowDocument PlainLicenceToDocument(string text, Brush textBrush, Brush muted, Brush accent, FontFamily body)
    {
        var doc = new FlowDocument { FontFamily = body, FontSize = 12.5, Foreground = textBrush, PagePadding = new Thickness(0), TextAlignment = TextAlignment.Left };
        var lines = text.Replace("\r\n", "\n").Split('\n');
        var para = new List<string>();
        Thickness paraMargin = new(0, 0, 0, 10);
        void Flush()
        {
            if (para.Count == 0) return;
            var p = new Paragraph { Margin = paraMargin };
            AddInlines(p.Inlines, string.Join(" ", para), accent);
            doc.Blocks.Add(p);
            para.Clear();
            paraMargin = new Thickness(0, 0, 0, 10);
        }
        for (int i = 0; i < lines.Length; i++)
        {
            string raw = lines[i].TrimEnd();
            if (raw.Length == 0) { Flush(); continue; }
            int indent = raw.Length - raw.TrimStart().Length;
            string line = raw.Trim();
            if (indent >= 10)
            {
                // Centred title lines (licence name, version, "Preamble", "TERMS AND CONDITIONS"…).
                Flush();
                bool big = i == 0;
                doc.Blocks.Add(new Paragraph(new Run(line)) { FontWeight = FontWeights.SemiBold, FontSize = big ? 17 : 14, TextAlignment = TextAlignment.Center, Margin = new Thickness(0, big ? 0 : 14, 0, 8) });
                continue;
            }
            if (Regex.IsMatch(line, @"^\d+\.\s+\S") && indent == 2)
            {
                Flush();
                doc.Blocks.Add(new Paragraph(new Run(line)) { FontWeight = FontWeights.SemiBold, FontSize = 13.5, Margin = new Thickness(0, 12, 0, 6) });
                continue;
            }
            if (Regex.IsMatch(line, @"^[a-z]\)\s") && indent == 4)
            {
                Flush();
                paraMargin = new Thickness(18, 0, 0, 6);
                para.Add(line);
                continue;
            }
            if (indent >= 4 && para.Count > 0 && paraMargin.Left > 0) { para.Add(line); continue; }   // continuation of a lettered clause
            if (indent >= 4)
            {
                // Preformatted block (the "how to apply" sample notice).
                Flush();
                var pre = new Paragraph { FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 11.5, Foreground = muted, Margin = new Thickness(18, 0, 0, 10) };
                while (i < lines.Length && lines[i].TrimEnd().Length > 0 && lines[i].Length - lines[i].TrimStart().Length >= 4)
                {
                    if (pre.Inlines.Count > 0) pre.Inlines.Add(new LineBreak());
                    pre.Inlines.Add(new Run(lines[i].TrimEnd()[4..]));
                    i++;
                }
                i--;
                doc.Blocks.Add(pre);
                continue;
            }
            if (indent == 2 && para.Count > 0 && paraMargin.Left == 0) Flush();   // a new paragraph starts with a two-space indent
            if (paraMargin.Left > 0 && indent < 4) Flush();
            para.Add(line);
        }
        Flush();
        return doc;
    }

    /// <summary>
    /// The GraXpert model credit files: each is a licence line, a thank-you line and one contributor per
    /// line. Shown as a titled section with the names flowing in one paragraph.
    /// </summary>
    public static FlowDocument ModelCreditsToDocument(IEnumerable<(string title, string text)> files, Brush textBrush, Brush muted, Brush accent, Brush rule, FontFamily body)
    {
        var doc = new FlowDocument { FontFamily = body, FontSize = 12.5, Foreground = textBrush, PagePadding = new Thickness(0), TextAlignment = TextAlignment.Left };
        bool first = true;
        foreach (var (title, text) in files)
        {
            if (!first) doc.Blocks.Add(new BlockUIContainer(new System.Windows.Controls.Border { Height = 1, Background = rule, Margin = new Thickness(0, 8, 0, 12) }));
            first = false;
            doc.Blocks.Add(new Paragraph(new Run(title)) { FontWeight = FontWeights.SemiBold, FontSize = 15, Margin = new Thickness(0, 0, 0, 6) });
            var lines = text.Replace("\r\n", "\n").Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0).ToList();
            var names = new List<string>();
            foreach (var line in lines)
            {
                // Sentences (licence statement, thank-you) are paragraphs; short lines are contributor names.
                if (line.Length > 60 || line.EndsWith(':'))
                {
                    var p = new Paragraph { Margin = new Thickness(0, 0, 0, 8) };
                    AddInlines(p.Inlines, line, accent);
                    doc.Blocks.Add(p);
                }
                else names.Add(Regex.Replace(line, @"\s{2,}", " "));
            }
            if (names.Count > 0)
                doc.Blocks.Add(new Paragraph(new Run(string.Join("  ·  ", names))) { Foreground = muted, FontSize = 12, Margin = new Thickness(0, 0, 0, 10), LineHeight = 20 });
        }
        return doc;
    }

    private static string[] SplitRow(string row)
    {
        var cells = new List<string>();
        var sb = new System.Text.StringBuilder();
        bool code = false;
        for (int k = 1; k < row.Length; k++)          // skip the leading pipe
        {
            char c = row[k];
            if (c == '`') code = !code;
            if (c == '|' && !code) { cells.Add(sb.ToString().Trim()); sb.Clear(); }
            else sb.Append(c);
        }
        if (sb.Length > 0) cells.Add(sb.ToString().Trim());
        return cells.ToArray();
    }

    /// <summary>A pipe table as a Grid (a FlowDocument Table does not respect the viewer width reliably).</summary>
    private static Block BuildTable(List<string[]> rows, Brush text, Brush muted, Brush accent, Brush rule)
    {
        int cols = rows.Max(r => r.Length);
        var grid = new System.Windows.Controls.Grid { Margin = new Thickness(0, 4, 0, 12) };
        // Column widths follow the amount of text in each column, within sensible bounds.
        for (int c = 0; c < cols; c++)
        {
            double avg = rows.Skip(1).Select(r => c < r.Length ? r[c].Length : 0).DefaultIfEmpty(0).Average();
            grid.ColumnDefinitions.Add(new System.Windows.Controls.ColumnDefinition { Width = new GridLength(Math.Clamp(avg, 12, 60), GridUnitType.Star) });
        }
        for (int r = 0; r < rows.Count; r++)
        {
            grid.RowDefinitions.Add(new System.Windows.Controls.RowDefinition { Height = GridLength.Auto });
            bool header = r == 0;
            for (int c = 0; c < cols; c++)
            {
                var tb = new System.Windows.Controls.TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 12, Foreground = header ? text : muted, Padding = new Thickness(6, 5, 8, 5) };
                if (header) tb.FontWeight = FontWeights.SemiBold;
                AddInlines(tb.Inlines, c < rows[r].Length ? rows[r][c] : "", accent);
                var cell = new System.Windows.Controls.Border { Child = tb, BorderBrush = rule, BorderThickness = new Thickness(0, 0, 0, 1) };
                System.Windows.Controls.Grid.SetRow(cell, r);
                System.Windows.Controls.Grid.SetColumn(cell, c);
                grid.Children.Add(cell);
            }
        }
        return new BlockUIContainer(grid) { Margin = new Thickness(0) };
    }

    private static readonly Regex Inline = new(@"(\*\*(?<b>.+?)\*\*)|(`(?<c>[^`]+)`)|(\[(?<lt>[^\]]+)\]\((?<lu>[^)]+)\))|(\*(?<i>[^*]+)\*)|(?<u>https?://[^\s)]+)", RegexOptions.Compiled);

    private static void AddInlines(InlineCollection target, string text, Brush accent)
    {
        int pos = 0;
        foreach (Match m in Inline.Matches(text))
        {
            if (m.Index > pos) target.Add(new Run(text[pos..m.Index]));
            if (m.Groups["b"].Success) { var bold = new Bold(); AddInlines(bold.Inlines, m.Groups["b"].Value, accent); target.Add(bold); }
            else if (m.Groups["c"].Success) target.Add(new Run(m.Groups["c"].Value) { FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 11.5 });
            else if (m.Groups["lt"].Success) target.Add(Link(m.Groups["lt"].Value, m.Groups["lu"].Value, accent));
            else if (m.Groups["i"].Success) { var it = new Italic(); AddInlines(it.Inlines, m.Groups["i"].Value, accent); target.Add(it); }
            else if (m.Groups["u"].Success) target.Add(Link(m.Groups["u"].Value, m.Groups["u"].Value, accent));
            pos = m.Index + m.Length;
        }
        if (pos < text.Length) target.Add(new Run(text[pos..]));
    }

    private static Hyperlink Link(string label, string url, Brush accent)
    {
        var link = new Hyperlink(new Run(label)) { Foreground = accent, TextDecorations = null };
        if (Uri.TryCreate(url, UriKind.Absolute, out var uri)) link.NavigateUri = uri;
        link.RequestNavigate += (_, e) =>
        {
            try { Process.Start(new ProcessStartInfo(e.Uri.AbsoluteUri) { UseShellExecute = true }); } catch (Exception) { /* no browser */ }
            e.Handled = true;
        };
        return link;
    }
}
