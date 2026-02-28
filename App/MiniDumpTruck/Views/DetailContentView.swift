import SwiftUI
import MiniDumpTruckCore

struct DetailContentView: View {
    let document: MinidumpDocument
    @Bindable var viewModel: DumpViewModel

    var body: some View {
        Group {
            switch viewModel.selectedSection {
            case .summary:
                SummaryView(document: document, viewModel: viewModel)
            case .systemInfo:
                if let systemInfo = document.systemInfo {
                    SystemInfoView(systemInfo: systemInfo)
                } else {
                    ContentUnavailableView(
                        "System Info Not Available",
                        systemImage: "info.circle",
                        description: Text("This dump does not contain system information")
                    )
                }
            case .miscInfo:
                if let miscInfo = document.miscInfo {
                    MiscInfoView(miscInfo: miscInfo)
                } else {
                    ContentUnavailableView(
                        "Misc Info Not Available",
                        systemImage: "ellipsis.circle",
                        description: Text("This dump does not contain miscellaneous process information")
                    )
                }
            case .exception:
                if let exception = document.exception {
                    ExceptionView(
                        exception: exception,
                        document: document,
                        viewModel: viewModel
                    )
                } else {
                    ContentUnavailableView(
                        "No Exception Data",
                        systemImage: "exclamationmark.triangle",
                        description: Text("This dump does not contain exception information. It may not be a crash dump.")
                    )
                }
            case .analyze:
                if document.exception != nil {
                    CrashAnalysisView(document: document, viewModel: viewModel)
                } else {
                    ContentUnavailableView(
                        "Analysis Not Available",
                        systemImage: "wand.and.stars",
                        description: Text("Crash analysis requires exception data. This dump does not contain an exception record.")
                    )
                }
            case .threads:
                if document.threads.isEmpty {
                    ContentUnavailableView(
                        "No Threads",
                        systemImage: "text.line.first.and.arrowtriangle.forward",
                        description: Text("This dump does not contain thread information")
                    )
                } else {
                    ThreadListView(document: document, viewModel: viewModel)
                }
            case .modules:
                if document.modules.isEmpty {
                    ContentUnavailableView(
                        "No Modules",
                        systemImage: "shippingbox",
                        description: Text("This dump does not contain module information")
                    )
                } else {
                    ModuleListView(document: document, viewModel: viewModel)
                }
            case .handles:
                if document.handles.isEmpty {
                    ContentUnavailableView(
                        "No Handle Data",
                        systemImage: "hand.raised",
                        description: Text("This dump does not contain handle information")
                    )
                } else {
                    HandleDataView(document: document, viewModel: viewModel)
                }
            case .memory:
                if document.memoryRegions.isEmpty {
                    ContentUnavailableView(
                        "No Memory Data",
                        systemImage: "memorychip",
                        description: Text("This dump does not contain memory data")
                    )
                } else {
                    MemoryListView(document: document, viewModel: viewModel)
                }
            case .streams:
                if let directory = document.streamDirectory {
                    StreamListView(directory: directory)
                } else {
                    ContentUnavailableView(
                        "No Stream Directory",
                        systemImage: "list.bullet",
                        description: Text("Could not read stream directory from this dump")
                    )
                }
            }
        }
        .frame(minWidth: 300)
    }
}

struct DetailInspectorView: View {
    let document: MinidumpDocument
    @Bindable var viewModel: DumpViewModel

    /// Sections that have selectable items for the detail pane
    private var sectionUsesDetailPane: Bool {
        switch viewModel.selectedSection {
        case .threads, .modules, .memory:
            return true
        default:
            return false
        }
    }

    var body: some View {
        Group {
            if let selection = viewModel.detailSelection {
                switch selection {
                case .thread(let threadId):
                    if let thread = document.threads.first(where: { $0.id == threadId }) {
                        ThreadDetailView(thread: thread, document: document)
                    } else {
                        ContentUnavailableView(
                            "Thread Not Found",
                            systemImage: "questionmark.circle",
                            description: Text("Thread \(threadId) is no longer available")
                        )
                    }
                case .module(let moduleId):
                    if let module = document.modules.first(where: { $0.id == moduleId }) {
                        ModuleDetailView(module: module)
                    } else {
                        ContentUnavailableView(
                            "Module Not Found",
                            systemImage: "questionmark.circle",
                            description: Text("The selected module is no longer available")
                        )
                    }
                case .memoryRegion(let regionId):
                    if let region = document.memoryRegions.first(where: { $0.id == regionId }) {
                        HexView(region: region, document: document, viewModel: viewModel)
                    } else {
                        ContentUnavailableView(
                            "Memory Region Not Found",
                            systemImage: "questionmark.circle",
                            description: Text("The selected memory region is no longer available")
                        )
                    }
                case .stream:
                    Text("Select a stream to view details")
                        .foregroundStyle(.secondary)
                }
            } else if sectionUsesDetailPane {
                detailPrompt
            } else {
                Color.clear
            }
        }
        .frame(minWidth: sectionUsesDetailPane ? 400 : 0)
        .frame(maxWidth: sectionUsesDetailPane ? .infinity : 0)
    }

    private var detailPrompt: some View {
        ContentUnavailableView {
            Label(promptTitle, systemImage: promptIcon)
        } description: {
            Text(promptDescription)
        }
    }

    private var promptTitle: String {
        switch viewModel.selectedSection {
        case .threads: return "Select a Thread"
        case .modules: return "Select a Module"
        case .memory: return "Select a Memory Region"
        default: return ""
        }
    }

    private var promptIcon: String {
        switch viewModel.selectedSection {
        case .threads: return "text.line.first.and.arrowtriangle.forward"
        case .modules: return "shippingbox"
        case .memory: return "memorychip"
        default: return "square.dashed"
        }
    }

    private var promptDescription: String {
        switch viewModel.selectedSection {
        case .threads: return "Choose a thread from the list to view its registers and stack"
        case .modules: return "Choose a module from the list to view its details"
        case .memory: return "Choose a memory region from the list to view its hex contents"
        default: return ""
        }
    }
}
