import SwiftUI

/// View modifier that observes the `.openHelp` notification and opens the
/// help window via SwiftUI's environment-injected `openWindow` action.
/// Applied to the WindowGroup's root so menu/keyboard shortcuts wired to
/// `.openHelp` reach a view that has `openWindow` in scope.
private struct HelpWindowHandler: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .openHelp)) { _ in
                openWindow(id: "help")
            }
    }
}

extension View {
    func helpWindowHandler() -> some View {
        modifier(HelpWindowHandler())
    }
}

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: "truck.box.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text("MiniDumpTruck")
                            .font(.title)
                            .fontWeight(.bold)
                        Text("Windows Crash Dump Analyzer for macOS")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                helpSection("Overview") {
                    Text("MiniDumpTruck lets you open and analyze Windows minidump (.dmp) files on macOS. It parses the binary dump format and presents crash data in an interactive interface \u{2014} no Windows or WinDbg required.")
                }

                helpSection("Supported File Types") {
                    Label(".dmp", systemImage: "doc")
                    Label(".mdmp", systemImage: "doc")
                    Label(".minidump", systemImage: "doc")
                    Label(".zip (containing a .dmp)", systemImage: "doc.zipper")
                }

                helpSection("Sidebar Navigation") {
                    navigationItem("Summary", icon: "doc.text", description: "Crash overview with exception and system context")
                    navigationItem("Threads", icon: "text.line.first.and.arrowtriangle.forward", description: "Thread list with faulting thread highlighted")
                    navigationItem("Modules", icon: "shippingbox", description: "Loaded DLLs with addresses, versions, and search")
                    navigationItem("Memory", icon: "memorychip", description: "Memory regions with address lookup")
                    navigationItem("Exception", icon: "exclamationmark.triangle", description: "Exception details and crash context")
                    navigationItem("System Info", icon: "cpu", description: "OS version, architecture, and processor details")
                    navigationItem("Handles", icon: "door.left.hand.open", description: "Open kernel object handles")
                    navigationItem("Crash Analysis", icon: "wand.and.stars", description: "Automated diagnosis with blame attribution")
                    navigationItem("Hex Viewer", icon: "number", description: "Raw memory inspection with search")
                    navigationItem("Stream Directory", icon: "list.bullet.rectangle", description: "Low-level stream index")
                }

                helpSection("Keyboard Shortcuts") {
                    shortcutRow("Go to Address", shortcut: "\u{2318}G")
                    shortcutRow("Export HTML Report", shortcut: "\u{21E7}\u{2318}E")
                    shortcutRow("Export CSV", shortcut: "\u{21E7}\u{2318}S")
                    shortcutRow("MiniDumpTruck Help", shortcut: "\u{2318}?")
                }

                helpSection("Command-Line Tool") {
                    Text("MiniDumpTruck includes a CLI for scripting and automation.")
                        .font(.callout)

                    cliCommandRow("analyze <path>", description: "Analyze a dump file or directory of dumps")
                    cliCommandRow("export <path>", description: "Export as text, HTML, CSV, or JSON (-f format)")
                    cliCommandRow("info <path>", description: "Quick triage summary of a dump file")

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Key flags:")
                            .font(.callout)
                            .fontWeight(.medium)
                        cliOptionRow("-v, --verbose", description: "Include registers and memory regions")
                        cliOptionRow("-f, --format", description: "Output format: text, html, csv, json")
                        cliOptionRow("-s, --summary", description: "Batch summary only (directory mode)")
                        cliOptionRow("-j, --jobs N", description: "Concurrent analyses (default: 4)")
                        cliOptionRow("--manual", description: "Display the full CLI manual")
                    }

                    Text("Run **minidumptruck-cli --manual** for the complete reference.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                helpSection("Tips") {
                    tipRow("Drag and drop a .dmp file onto the welcome screen to open it quickly.")
                    tipRow("Use Crash Analysis for automated diagnosis \u{2014} it walks the stack and attributes blame to a specific module.")
                    tipRow("The Hex Viewer lets you inspect raw memory bytes at any address captured in the dump.")
                    tipRow("Export reports as HTML for sharing or CSV for spreadsheet analysis.")
                }
            }
            .padding(24)
        }
    }

    private func helpSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private func navigationItem(_ name: String, icon: String, description: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.blue)
            Text(name)
                .fontWeight(.medium)
            Text("\u{2014} \(description)")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private func shortcutRow(_ action: String, shortcut: String) -> some View {
        HStack {
            Text(action)
            Spacer()
            Text(shortcut)
                .font(.system(.callout, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
        .font(.callout)
    }

    private func cliCommandRow(_ command: String, description: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .frame(width: 20)
                .foregroundStyle(.green)
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .fontWeight(.medium)
            Text("\u{2014} \(description)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func cliOptionRow(_ flag: String, description: String) -> some View {
        HStack(spacing: 0) {
            Text(flag)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 130, alignment: .leading)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 28)
    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb")
                .foregroundStyle(.yellow)
                .frame(width: 20)
            Text(text)
                .font(.callout)
        }
    }
}
