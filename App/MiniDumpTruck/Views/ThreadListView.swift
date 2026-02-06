import SwiftUI
import MiniDumpTruckCore

struct ThreadListView: View {
    let document: MinidumpDocument
    @Bindable var viewModel: DumpViewModel

    var filteredThreads: [ThreadInfo] {
        let threads = document.threads
        if viewModel.threadSearchText.isEmpty {
            return threads
        }
        let searchText = viewModel.threadSearchText.lowercased()
        return threads.filter { thread in
            // Search by thread ID
            if String(thread.id).contains(searchText) {
                return true
            }
            // Search by thread name
            if let name = document.threadName(for: thread.id),
               name.lowercased().contains(searchText) {
                return true
            }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search threads by ID...", text: $viewModel.threadSearchText)
                    .textFieldStyle(.plain)

                if !viewModel.threadSearchText.isEmpty {
                    Button {
                        viewModel.threadSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(.bar)

            Divider()

            if filteredThreads.isEmpty && !viewModel.threadSearchText.isEmpty {
                ContentUnavailableView.search(text: viewModel.threadSearchText)
            } else {
                List(selection: Binding(
                    get: {
                        if case .thread(let id) = viewModel.detailSelection {
                            return id
                        }
                        return nil
                    },
                    set: { newValue in
                        if let id = newValue {
                            viewModel.detailSelection = .thread(id)
                        }
                    }
                )) {
                    ForEach(filteredThreads) { thread in
                        ThreadRowView(
                            thread: thread,
                            isFaulting: document.exception?.threadId == thread.id,
                            threadName: document.threadName(for: thread.id)
                        )
                        .tag(thread.id)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Threads (\(document.threads.count))")
    }
}

struct ThreadRowView: View {
    let thread: ThreadInfo
    let isFaulting: Bool
    let threadName: String?

    var body: some View {
        HStack {
            if isFaulting {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Thread \(thread.id)")
                        .fontWeight(.medium)

                    if let name = threadName, !name.isEmpty {
                        Text("(\(name))")
                            .font(.callout)
                            .foregroundStyle(.blue)
                    }

                    if isFaulting {
                        Text("Faulting")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.red.opacity(0.2))
                            .foregroundStyle(.red)
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 12) {
                    Text("Priority: \(thread.priorityDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if thread.suspendCount > 0 {
                        Text("Suspended: \(thread.suspendCount)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            if let context = thread.context {
                Text(String(format: "RIP: 0x%016llX", context.rip))
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
