import SwiftUI

struct SidebarView: View {
    let document: MinidumpDocument
    @Bindable var viewModel: DumpViewModel

    var body: some View {
        List {
            Section("Analysis") {
                ForEach(visibleSections, id: \.self) { section in
                    Button {
                        viewModel.selectedSection = section
                    } label: {
                        Label(section.rawValue, systemImage: section.systemImage)
                            .badge(badge(for: section))
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        viewModel.selectedSection == section
                            ? Color.accentColor.opacity(0.2)
                            : Color.clear
                    )
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
        case .exception:
            return document.exception != nil
        case .analyze:
            return document.exception != nil
        case .threads:
            return !document.threads.isEmpty
        case .modules:
            return !document.modules.isEmpty
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
        case .memory:
            return document.memoryRegions.count
        case .streams:
            return document.streamDirectory?.entries.count ?? 0
        default:
            return 0
        }
    }
}
