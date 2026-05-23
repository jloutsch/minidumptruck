import Foundation

/// CSS stylesheet for the HTML crash report. Lifted out of
/// `HTMLExporter.swift` so the exporter's report-building code isn't
/// buried under multiple kilobytes of static styles. The content is the
/// same — variables for light/dark mode plus per-element rules.
enum HTMLExporterCSS {
    static let stylesheet = """
        :root {
            --bg: #ffffff;
            --fg: #1a1a1a;
            --bg-secondary: #f5f5f7;
            --border: #d1d1d6;
            --accent: #0071e3;
            --header-bg: #1d1d1f;
            --header-fg: #f5f5f7;
            --table-stripe: #f9f9fb;
            --mono-bg: #f0f0f2;
            --red: #ff3b30;
            --orange: #ff9500;
            --green: #34c759;
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --bg: #1c1c1e;
                --fg: #f5f5f7;
                --bg-secondary: #2c2c2e;
                --border: #3a3a3c;
                --accent: #0a84ff;
                --header-bg: #000000;
                --header-fg: #f5f5f7;
                --table-stripe: #252528;
                --mono-bg: #2c2c2e;
                --red: #ff453a;
                --orange: #ff9f0a;
                --green: #30d158;
            }
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: var(--bg);
            color: var(--fg);
            line-height: 1.6;
            max-width: 1200px;
            margin: 0 auto;
            padding: 20px;
        }
        header {
            background: var(--header-bg);
            color: var(--header-fg);
            padding: 24px 32px;
            border-radius: 12px;
            margin-bottom: 24px;
        }
        header h1 { font-size: 1.5em; margin-bottom: 4px; }
        header .subtitle { opacity: 0.7; font-size: 0.9em; }
        header .timestamp { opacity: 0.5; font-size: 0.8em; margin-top: 8px; }
        nav#toc {
            background: var(--bg-secondary);
            padding: 12px 16px;
            border-radius: 8px;
            margin-bottom: 24px;
            display: flex;
            flex-wrap: wrap;
            gap: 8px;
            align-items: center;
        }
        nav#toc a {
            color: var(--accent);
            text-decoration: none;
            padding: 4px 10px;
            border-radius: 6px;
            font-size: 0.85em;
        }
        nav#toc a:hover { background: var(--border); }
        section, details {
            background: var(--bg-secondary);
            border: 1px solid var(--border);
            border-radius: 10px;
            padding: 20px;
            margin-bottom: 16px;
        }
        details > details {
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 12px;
            margin: 8px 0;
        }
        h2 {
            font-size: 1.2em;
            margin-bottom: 12px;
            display: inline;
        }
        h3 { font-size: 1em; margin: 16px 0 8px 0; }
        summary {
            cursor: pointer;
            padding: 4px 0;
            list-style: revert;
        }
        summary h2 { margin-bottom: 0; }
        table { width: 100%; border-collapse: collapse; margin: 8px 0; }
        .info-table th {
            text-align: left;
            width: 180px;
            padding: 6px 12px;
            font-weight: 600;
            color: var(--fg);
            vertical-align: top;
        }
        .info-table td { padding: 6px 12px; }
        .data-table th {
            text-align: left;
            padding: 8px 12px;
            font-weight: 600;
            border-bottom: 2px solid var(--border);
            font-size: 0.85em;
            text-transform: uppercase;
            letter-spacing: 0.03em;
        }
        .data-table td {
            padding: 6px 12px;
            border-bottom: 1px solid var(--border);
            font-size: 0.9em;
        }
        .data-table tbody tr:nth-child(even) { background: var(--table-stripe); }
        .mono, code {
            font-family: 'SF Mono', 'Menlo', 'Consolas', monospace;
            font-size: 0.85em;
        }
        code {
            background: var(--mono-bg);
            padding: 2px 6px;
            border-radius: 4px;
        }
        .badge {
            display: inline-block;
            padding: 2px 10px;
            border-radius: 12px;
            font-size: 0.75em;
            font-weight: 600;
            vertical-align: middle;
        }
        .badge-sm { padding: 1px 6px; font-size: 0.7em; }
        .badge-green { background: var(--green); color: #fff; }
        .badge-orange { background: var(--orange); color: #fff; }
        .badge-red { background: var(--red); color: #fff; }
        footer {
            text-align: center;
            padding: 24px;
            font-size: 0.8em;
            opacity: 0.5;
        }
        @media print {
            body { max-width: none; padding: 0; }
            header { border-radius: 0; }
            section, details { break-inside: avoid; border-radius: 0; }
            details { open: true; }
            nav#toc { display: none; }
        }
    """
}
