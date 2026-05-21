import SwiftUI
import MiniDumpTruckCore

struct SidebarView: View {
    let document: MinidumpDocument
    @Bindable var viewModel: DumpViewModel

    /// Bridge the view-model's non-optional selection to the optional
    /// binding `List(selection:)` expects for single selection.
    ///
    /// Intentionally drops nil writes: the view model contract is that
    /// some section is always selected. Deselect attempts (Cmd-click on
    /// the current row, blank-area click) are no-ops, mirroring the
    /// behavior of the previous Button-based implementation.
    private var sectionBinding: Binding<NavigationSection?> {
        Binding(
            get: { viewModel.selectedSection },
            set: { if let new = $0 { viewModel.selectedSection = new } }
        )
    }

    var body: some View {
        // Native List(selection:) with NavigationLink rows is Apple's
        // canonical NavigationSplitView sidebar pattern. NavigationLink(
        // value:) makes each row keyboard-focusable so up/down arrows
        // move selection — a plain Label.tag() does not register as a
        // focusable item on macOS sidebars.
        List(selection: sectionBinding) {
            Section("Analysis") {
                ForEach(visibleSections, id: \.self) { section in
                    NavigationLink(value: section) {
                        Label(section.rawValue, systemImage: section.systemImage)
                            .badge(badge(for: section))
                    }
                }
            }
        }
        .navigationTitle("MiniDumpTruck")
        .listStyle(.sidebar)
        // If the bound document changes such that the currently selected
        // section is no longer visible (e.g. user opens a dump without an
        // exception while `.exception` was selected), List(selection:)
        // would render no highlight but the property would still hold
        // the stale value. Snap back to a guaranteed-visible default.
        .onChange(of: visibleSections) { _, newVisible in
            if !newVisible.contains(viewModel.selectedSection),
               let fallback = newVisible.first {
                viewModel.selectedSection = fallback
            }
        }
    }

    private var visibleSections: [NavigationSection] {
        NavigationSection.allCases.filter { shouldShow($0) }
    }

    private func shouldShow(_ section: NavigationSection) -> Bool {
        switch section {
        case .summary:
            return true
        case .systemInfo:
            return document.systemInfo != nil
        case .miscInfo:
            return document.miscInfo != nil
        case .exception:
            return document.exception != nil
        case .analyze:
            return document.exception != nil
        case .threads:
            return !document.threads.isEmpty
        case .modules:
            return !document.modules.isEmpty
        case .handles:
            return !document.handles.isEmpty
        case .memory:
            return !document.memoryRegions.isEmpty || !document.memoryInfoEntries.isEmpty
        case .streams:
            return document.streamDirectory != nil
        }
    }

    private func badge(for section: NavigationSection) -> Int {
        switch section {
        case .threads:
            return document.threads.count
        case .modules:
            return document.modules.count
        case .handles:
            return document.handles.count
        case .memory:
            return document.memoryRegions.count
        case .streams:
            return document.streamDirectory?.entries.count ?? 0
        default:
            return 0
        }
    }
}
