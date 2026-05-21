import SwiftUI
import MiniDumpTruckCore

struct SidebarView: View {
    let document: MinidumpDocument
    @Bindable var viewModel: DumpViewModel

    /// Bridge the view-model's non-optional selection to the optional
    /// binding `List(selection:)` expects for single selection.
    private var sectionBinding: Binding<NavigationSection?> {
        Binding(
            get: { viewModel.selectedSection },
            set: { if let new = $0 { viewModel.selectedSection = new } }
        )
    }

    var body: some View {
        // Native List(selection:) gives us arrow-key navigation, native
        // selection highlighting, and correct VoiceOver row semantics —
        // none of which the prior Button + listRowBackground pattern
        // delivered.
        List(selection: sectionBinding) {
            Section("Analysis") {
                ForEach(visibleSections, id: \.self) { section in
                    Label(section.rawValue, systemImage: section.systemImage)
                        .badge(badge(for: section))
                        .tag(section)
                }
            }
        }
        .navigationTitle("MiniDumpTruck")
        .listStyle(.sidebar)
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
