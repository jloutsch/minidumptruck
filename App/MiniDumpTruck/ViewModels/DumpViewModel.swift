import SwiftUI
import MiniDumpTruckCore

/// Navigation sections in the sidebar
enum NavigationSection: String, CaseIterable, Identifiable {
    case summary = "Summary"
    case systemInfo = "System Info"
    case miscInfo = "Misc Info"
    case exception = "Exception"
    case analyze = "Analyze"
    case threads = "Threads"
    case modules = "Modules"
    case handles = "Handles"
    case memory = "Memory"
    case streams = "Streams"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .summary: return "doc.text"
        case .systemInfo: return "info.circle"
        case .miscInfo: return "ellipsis.circle"
        case .exception: return "exclamationmark.triangle"
        case .analyze: return "wand.and.stars"
        case .threads: return "text.line.first.and.arrowtriangle.forward"
        case .modules: return "shippingbox"
        case .handles: return "hand.raised"
        case .memory: return "memorychip"
        case .streams: return "list.bullet"
        }
    }
}

/// Selected item in the detail view
enum DetailSelection: Hashable {
    case thread(UInt32)  // Thread ID
    case module(UUID)    // Module UUID
    case memoryRegion(UUID)
    case stream(UUID)
}

/// Main view model for the dump viewer
@MainActor
@Observable
class DumpViewModel {
    var selectedSection: NavigationSection = .summary {
        didSet {
            if oldValue != selectedSection {
                // Clear stale detail selection when switching sections
                detailSelection = nil
            }
        }
    }
    var detailSelection: DetailSelection?

    // Search/filter state
    var moduleSearchText: String = ""
    var threadSearchText: String = ""
    var handleSearchText: String = ""
    var memoryAddressText: String = ""

    // Display options
    var showHexValues: Bool = true
    var bytesPerRow: Int = 16

    // Go to address state
    var showGoToAddressSheet: Bool = false
    var goToAddressText: String = ""

    // Reference to document for address lookups (set by ContentView)
    weak var documentReference: MinidumpDocumentWrapper?

    /// Server-fetched PDB public symbol tables, keyed by module base
    /// address. Empty until `loadSymbols(for:)` finishes. Views that
    /// run `CrashAnalyzer` pass this dict in so the analyzer's
    /// symbolicator can resolve real function names.
    var pdbTables: [UInt64: PDBSymbolTable] = [:]

    /// True while a `SymbolicationService` is currently downloading
    /// and parsing PDBs for the open dump. Views can show a spinner
    /// or a "Resolving symbols..." note.
    var isResolvingSymbols: Bool = false

    /// Kick off async symbol resolution for the given dump. Failures
    /// (network, malformed PDB) are silent: the dict just stays empty
    /// and views fall back to slice-1 (PE export) symbols or
    /// module+offset.
    ///
    /// The `defer` is load-bearing: if the SwiftUI `.task(id:)` that
    /// invoked us cancels (because the user switched dumps), the
    /// await throws CancellationError and Swift unwinds through the
    /// defer — leaving `isResolvingSymbols == false` so the next
    /// dump's load isn't permanently blocked. Without the defer, the
    /// flag could wedge true and every subsequent dump would silently
    /// skip resolution.
    func loadSymbols(for dump: ParsedMinidump, service: SymbolicationService) async {
        isResolvingSymbols = true
        defer { isResolvingSymbols = false }
        let tables = await service.loadSymbols(for: dump)
        self.pdbTables = tables
    }

    func selectThread(_ thread: ThreadInfo) {
        selectedSection = .threads
        detailSelection = .thread(thread.id)
    }

    func selectModule(_ module: ModuleInfo) {
        selectedSection = .modules
        detailSelection = .module(module.id)
    }

    func goToAddress(_ address: UInt64) {
        selectedSection = .memory
        memoryAddressText = String(format: "0x%016llX", address)

        // Try to find and select the memory region containing this address
        if let wrapper = documentReference,
           let region = wrapper.document.memoryRegions.first(where: { $0.contains(address: address) }) {
            detailSelection = .memoryRegion(region.id)
        }
    }

    func goToAddressInDocument(_ address: UInt64, document: MinidumpDocument) {
        selectedSection = .memory
        memoryAddressText = String(format: "0x%016llX", address)

        // Find and select the memory region containing this address
        if let region = document.memoryRegions.first(where: { $0.contains(address: address) }) {
            detailSelection = .memoryRegion(region.id)
        }
    }

    func parseAddress(_ text: String) -> UInt64? {
        var cleaned = text.trimmingCharacters(in: .whitespaces).lowercased()
        // Strip leading 0x prefix only once
        if cleaned.hasPrefix("0x") {
            cleaned = String(cleaned.dropFirst(2))
        }
        return UInt64(cleaned, radix: 16)
    }
}

/// Wrapper to allow weak reference to document
class MinidumpDocumentWrapper {
    let document: MinidumpDocument

    init(document: MinidumpDocument) {
        self.document = document
    }
}
