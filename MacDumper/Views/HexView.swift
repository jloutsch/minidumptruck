import SwiftUI

struct HexView: View {
    let region: MemoryRegion
    let document: MinidumpDocument
    @Bindable var viewModel: DumpViewModel

    @State private var searchText: String = ""
    @State private var searchResults: [Int] = []
    @State private var currentSearchIndex: Int = 0
    @State private var jumpAddress: String = ""
    @State private var scrollToOffset: Int?

    private let bytesPerRow = 16
    private let maxReadSize = 1024 * 1024  // 1MB max

    var memoryData: Data? {
        let size = Int(min(region.regionSize, UInt64(maxReadSize)))
        return document.readMemory(at: region.baseAddress, size: size)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with region info
            headerView

            Divider()

            // Search and jump bar
            searchBar

            Divider()

            // Hex content
            if let data = memoryData {
                hexContentView(data: data)
            } else {
                ContentUnavailableView(
                    "Memory Not Available",
                    systemImage: "memorychip",
                    description: Text("Could not read memory for this region")
                )
            }
        }
        .navigationTitle("Memory View")
    }

    private var headerView: some View {
        HStack {
            Text("Region: \(String(format: "0x%016llX", region.baseAddress)) - \(String(format: "0x%016llX", region.endAddress))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Text("Size: \(ByteCountFormatter.string(fromByteCount: Int64(region.regionSize), countStyle: .memory))")
                .font(.caption)
                .foregroundStyle(.secondary)

            if region.regionSize > UInt64(maxReadSize) {
                Text("(showing first 1MB)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            // Hex search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search hex (e.g., 4D5A)...", text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        performSearch()
                    }

                if !searchText.isEmpty {
                    if !searchResults.isEmpty {
                        Text("\(currentSearchIndex + 1)/\(searchResults.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button {
                            navigateSearch(forward: false)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.plain)

                        Button {
                            navigateSearch(forward: true)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        searchText = ""
                        searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 300)

            Divider()
                .frame(height: 20)

            // Jump to address
            HStack {
                Image(systemName: "arrow.right.circle")
                    .foregroundStyle(.secondary)
                TextField("Jump to address...", text: $jumpAddress)
                    .textFieldStyle(.plain)
                    .frame(width: 150)
                    .onSubmit {
                        jumpToAddress()
                    }
            }
        }
        .padding(8)
        .background(.bar)
    }

    private func hexContentView(data: Data) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let rowCount = (data.count + bytesPerRow - 1) / bytesPerRow
                    ForEach(0..<rowCount, id: \.self) { row in
                        let rowOffset = row * bytesPerRow
                        if rowOffset < data.count {
                            HexRowView(
                                address: region.baseAddress + UInt64(rowOffset),
                                data: data,
                                offset: rowOffset,
                                bytesPerRow: bytesPerRow,
                                highlightOffsets: searchResults
                            )
                            .id(rowOffset)
                        }
                    }
                }
                .padding()
            }
            .fontDesign(.monospaced)
            .font(.system(size: 12))
            .onChange(of: scrollToOffset) { _, newValue in
                if let offset = newValue {
                    let rowOffset = (offset / bytesPerRow) * bytesPerRow
                    withAnimation {
                        proxy.scrollTo(rowOffset, anchor: .center)
                    }
                }
            }
        }
    }

    private func performSearch() {
        guard let data = memoryData else { return }

        // Parse hex string
        let cleaned = searchText.replacingOccurrences(of: " ", with: "")
        guard cleaned.count >= 2, cleaned.count % 2 == 0 else {
            searchResults = []
            return
        }

        var searchBytes: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            if let byte = UInt8(String(cleaned[index..<nextIndex]), radix: 16) {
                searchBytes.append(byte)
            } else {
                searchResults = []
                return
            }
            index = nextIndex
        }

        // Search for pattern
        var results: [Int] = []
        let dataBytes = Array(data)
        for i in 0...(dataBytes.count - searchBytes.count) {
            var match = true
            for j in 0..<searchBytes.count {
                if dataBytes[i + j] != searchBytes[j] {
                    match = false
                    break
                }
            }
            if match {
                results.append(i)
                if results.count >= 1000 { break }  // Limit results
            }
        }

        searchResults = results
        currentSearchIndex = 0
        if let first = results.first {
            scrollToOffset = first
        }
    }

    private func navigateSearch(forward: Bool) {
        guard !searchResults.isEmpty else { return }

        if forward {
            currentSearchIndex = (currentSearchIndex + 1) % searchResults.count
        } else {
            currentSearchIndex = (currentSearchIndex - 1 + searchResults.count) % searchResults.count
        }

        scrollToOffset = searchResults[currentSearchIndex]
    }

    private func jumpToAddress() {
        let cleaned = jumpAddress.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: "0x", with: "")

        guard let address = UInt64(cleaned, radix: 16) else { return }

        // Check if address is in this region
        if address >= region.baseAddress && address < region.endAddress {
            let offset = Int(address - region.baseAddress)
            scrollToOffset = offset
        }
    }
}

struct HexRowView: View {
    let address: UInt64
    let data: Data
    let offset: Int
    let bytesPerRow: Int
    var highlightOffsets: [Int] = []

    var rowBytes: [UInt8] {
        let startIndex = data.startIndex + offset
        let endIndex = min(startIndex + bytesPerRow, data.endIndex)
        guard startIndex < data.endIndex else { return [] }
        return Array(data[startIndex..<endIndex])
    }

    var body: some View {
        HStack(spacing: 0) {
            // Address
            Text(String(format: "%016llX", address))
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)

            Text("  ")

            // Hex bytes
            HStack(spacing: 4) {
                ForEach(Array(rowBytes.enumerated()), id: \.offset) { index, byte in
                    let globalOffset = offset + index
                    Text(String(format: "%02X", byte))
                        .foregroundStyle(byteColor(byte))
                        .background(
                            highlightOffsets.contains(globalOffset)
                                ? Color.yellow.opacity(0.4)
                                : Color.clear
                        )

                    // Add extra space after 8 bytes
                    if index == 7 {
                        Text(" ")
                    }
                }

                // Pad remaining space
                ForEach(rowBytes.count..<bytesPerRow, id: \.self) { index in
                    Text("  ")
                    if index == 7 {
                        Text(" ")
                    }
                }
            }
            .frame(width: 400, alignment: .leading)

            Text("  ")

            // ASCII representation
            Text(asciiRepresentation)
                .foregroundStyle(.blue)
        }
        .padding(.vertical, 1)
    }

    private var asciiRepresentation: String {
        String(rowBytes.map { byte in
            if byte >= 32 && byte < 127 {
                return Character(UnicodeScalar(byte))
            }
            return "."
        })
    }

    private func byteColor(_ byte: UInt8) -> Color {
        if byte == 0 {
            return .secondary
        } else if byte >= 32 && byte < 127 {
            return .primary
        }
        return .orange
    }
}

// Preview helper
struct HexView_Previews: PreviewProvider {
    static var previews: some View {
        Text("HexView Preview")
    }
}
