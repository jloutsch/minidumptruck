import SwiftUI
import MiniDumpTruckCore

@main
struct MiniDumpTruckApp: App {
    @State private var openedDocument: MinidumpDocument?

    var body: some Scene {
        // Main welcome window
        WindowGroup {
            if let document = openedDocument {
                ContentView(document: document)
            } else {
                WelcomeView(openedDocument: $openedDocument)
            }
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Go to Address...") {
                    NotificationCenter.default.post(name: .goToAddress, object: nil)
                }
                .keyboardShortcut("g", modifiers: .command)
            }
        }

        // Also support opening documents directly (double-click .dmp files)
        DocumentGroup(viewing: MinidumpDocument.self) { file in
            ContentView(document: file.document)
        }
    }
}

struct WelcomeView: View {
    @Binding var openedDocument: MinidumpDocument?
    @State private var isDragging = false
    @State private var isLoading = false
    @State private var loadingFileName: String = ""
    @State private var loadingFileSize: Int = 0

    var body: some View {
        ZStack {
            VStack(spacing: 24) {
                Spacer()

                // Custom dump truck icon
                DumpTruckIcon()
                    .frame(width: 120, height: 100)

                Text("MiniDumpTruck")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Windows Crash Dump Analyzer for macOS")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Spacer()

                // Drop zone
                VStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(
                                isDragging ? Color.blue : Color.secondary.opacity(0.3),
                                style: StrokeStyle(lineWidth: 2, dash: [8])
                            )
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(isDragging ? Color.blue.opacity(0.1) : Color.clear)
                            )
                            .frame(width: 400, height: 150)

                        VStack(spacing: 12) {
                            Image(systemName: "arrow.down.doc")
                                .font(.system(size: 40))
                                .foregroundStyle(isDragging ? .blue : .secondary)

                            Text("Drop a .dmp file here")
                                .font(.headline)
                                .foregroundStyle(isDragging ? .blue : .secondary)

                            Text("or")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button("Open File...") {
                                openFile()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isLoading)
                        }
                    }
                    .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
                        handleDrop(providers: providers)
                    }
                }

                Spacer()

                // Footer
                HStack(spacing: 20) {
                    Label("Threads", systemImage: "text.line.first.and.arrowtriangle.forward")
                    Label("Modules", systemImage: "shippingbox")
                    Label("Memory", systemImage: "memorychip")
                    Label("Analysis", systemImage: "wand.and.stars")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()
            }
            .disabled(isLoading)

            // Loading overlay
            if isLoading {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                        .opacity(0.9)

                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)

                        Text("Opening \(loadingFileName)...")
                            .font(.headline)

                        Text(ByteCountFormatter.string(fromByteCount: Int64(loadingFileSize), countStyle: .file))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text("Parsing minidump streams...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(40)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                .transition(.opacity)
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeInOut(duration: 0.2), value: isLoading)
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a Windows minidump file (.dmp)"

        if panel.runModal() == .OK, let url = panel.url {
            let ext = url.pathExtension.lowercased()
            guard ext == "dmp" || ext == "mdmp" || ext == "minidump" else {
                let alert = NSAlert()
                alert.messageText = "Unsupported File Type"
                alert.informativeText = "Please select a Windows minidump file (.dmp, .mdmp)."
                alert.alertStyle = .warning
                alert.runModal()
                return
            }
            loadDocument(from: url)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                return
            }

            // Validate file extension before loading
            let ext = url.pathExtension.lowercased()
            guard ext == "dmp" || ext == "mdmp" || ext == "minidump" else {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Unsupported File Type"
                    alert.informativeText = "Please drop a Windows minidump file (.dmp, .mdmp)."
                    alert.alertStyle = .warning
                    alert.runModal()
                }
                return
            }

            DispatchQueue.main.async {
                loadDocument(from: url)
            }
        }

        return true
    }

    private func loadDocument(from url: URL) {
        // Show loading state
        loadingFileName = url.lastPathComponent
        loadingFileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        isLoading = true

        // Parse in background to keep UI responsive
        Task.detached(priority: .userInitiated) {
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let parsedDump = try MinidumpParser.parse(data: data)
                let document = MinidumpDocument(parsedDump: parsedDump, fileSize: data.count)

                await MainActor.run {
                    isLoading = false
                    openedDocument = document
                }
            } catch {
                await MainActor.run {
                    isLoading = false

                    let alert = NSAlert()
                    alert.messageText = "Failed to Open File"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }
}

extension Notification.Name {
    static let goToAddress = Notification.Name("goToAddress")
}

/// Custom dump truck icon drawn with SwiftUI
struct DumpTruckIcon: View {
    var body: some View {
        Canvas { context, size in
            let width = size.width
            let height = size.height

            // Colors
            let truckBlue = Color.blue
            let darkBlue = Color.blue.opacity(0.8)
            let wheelGray = Color.gray.opacity(0.7)
            let dumpYellow = Color.orange

            // Scale factors
            let scale = min(width / 120, height / 100)
            let yOffset: CGFloat = 18 * scale  // Shift everything down so dump bed isn't cut off

            // Draw dump bed (rectangle rotated around back pivot point)
            // Raised at front, pivots from back-bottom corner
            let bedWidth: CGFloat = 70 * scale
            let bedHeight: CGFloat = 26 * scale
            let pivotX: CGFloat = 108 * scale
            let pivotY: CGFloat = 48 * scale + yOffset
            let angle: CGFloat = 32 * .pi / 180  // +32 degrees clockwise (raises front up)

            // Create rectangle and rotate around pivot point
            var dumpBed = Path()
            dumpBed.addRect(CGRect(x: 0, y: 0, width: bedWidth, height: bedHeight))

            var transform = CGAffineTransform.identity
            transform = transform.translatedBy(x: pivotX, y: pivotY)
            transform = transform.rotated(by: angle)
            transform = transform.translatedBy(x: -bedWidth, y: -bedHeight)

            dumpBed = dumpBed.applying(transform)
            context.fill(dumpBed, with: .color(dumpYellow))
            context.stroke(dumpBed, with: .color(dumpYellow.opacity(0.7)), lineWidth: 2 * scale)

            // Calculate front-bottom corner position for hydraulic arm
            let frontBottomLocal = CGPoint(x: 0, y: bedHeight)
            let cosA = cos(angle)
            let sinA = sin(angle)
            let frontBottomX = pivotX + (frontBottomLocal.x - bedWidth) * cosA - (frontBottomLocal.y - bedHeight) * sinA
            let frontBottomY = pivotY + (frontBottomLocal.x - bedWidth) * sinA + (frontBottomLocal.y - bedHeight) * cosA

            // Draw dump bed ridges (parallel lines inside the rotated rectangle)
            for i in 0..<5 {
                var ridge = Path()
                let ridgeY = CGFloat(4 + i * 5) * scale
                ridge.move(to: CGPoint(x: 4 * scale, y: ridgeY))
                ridge.addLine(to: CGPoint(x: bedWidth - 4 * scale, y: ridgeY))
                ridge = ridge.applying(transform)
                context.stroke(ridge, with: .color(dumpYellow.opacity(0.5)), lineWidth: 1.5 * scale)
            }

            // Draw cab (front of truck)
            var cab = Path()
            cab.addRoundedRect(
                in: CGRect(x: 5 * scale, y: 25 * scale + yOffset, width: 35 * scale, height: 30 * scale),
                cornerSize: CGSize(width: 5 * scale, height: 5 * scale)
            )
            context.fill(cab, with: .color(truckBlue))

            // Draw cab window
            var window = Path()
            window.addRoundedRect(
                in: CGRect(x: 10 * scale, y: 30 * scale + yOffset, width: 18 * scale, height: 12 * scale),
                cornerSize: CGSize(width: 3 * scale, height: 3 * scale)
            )
            context.fill(window, with: .color(.white.opacity(0.8)))

            // Draw chassis/frame
            var chassis = Path()
            chassis.addRect(CGRect(x: 5 * scale, y: 50 * scale + yOffset, width: 100 * scale, height: 8 * scale))
            context.fill(chassis, with: .color(darkBlue))

            // Draw wheels
            let wheelRadius: CGFloat = 12 * scale
            let wheelY: CGFloat = 58 * scale + yOffset

            // Front wheel
            var frontWheel = Path()
            frontWheel.addEllipse(in: CGRect(
                x: 15 * scale - wheelRadius,
                y: wheelY - wheelRadius,
                width: wheelRadius * 2,
                height: wheelRadius * 2
            ))
            context.fill(frontWheel, with: .color(wheelGray))

            // Front wheel hub
            var frontHub = Path()
            frontHub.addEllipse(in: CGRect(
                x: 15 * scale - wheelRadius * 0.4,
                y: wheelY - wheelRadius * 0.4,
                width: wheelRadius * 0.8,
                height: wheelRadius * 0.8
            ))
            context.fill(frontHub, with: .color(.gray))

            // Rear wheel 1
            var rearWheel1 = Path()
            rearWheel1.addEllipse(in: CGRect(
                x: 70 * scale - wheelRadius,
                y: wheelY - wheelRadius,
                width: wheelRadius * 2,
                height: wheelRadius * 2
            ))
            context.fill(rearWheel1, with: .color(wheelGray))

            // Rear wheel 1 hub
            var rearHub1 = Path()
            rearHub1.addEllipse(in: CGRect(
                x: 70 * scale - wheelRadius * 0.4,
                y: wheelY - wheelRadius * 0.4,
                width: wheelRadius * 0.8,
                height: wheelRadius * 0.8
            ))
            context.fill(rearHub1, with: .color(.gray))

            // Rear wheel 2
            var rearWheel2 = Path()
            rearWheel2.addEllipse(in: CGRect(
                x: 95 * scale - wheelRadius,
                y: wheelY - wheelRadius,
                width: wheelRadius * 2,
                height: wheelRadius * 2
            ))
            context.fill(rearWheel2, with: .color(wheelGray))

            // Rear wheel 2 hub
            var rearHub2 = Path()
            rearHub2.addEllipse(in: CGRect(
                x: 95 * scale - wheelRadius * 0.4,
                y: wheelY - wheelRadius * 0.4,
                width: wheelRadius * 0.8,
                height: wheelRadius * 0.8
            ))
            context.fill(rearHub2, with: .color(.gray))

            // Draw hydraulic arm (connects chassis to front-bottom of tilted bed)
            var hydraulic = Path()
            hydraulic.move(to: CGPoint(x: 45 * scale, y: 50 * scale + yOffset))
            hydraulic.addLine(to: CGPoint(x: frontBottomX, y: frontBottomY))
            context.stroke(hydraulic, with: .color(darkBlue), lineWidth: 4 * scale)

            // Draw exhaust pipe
            var exhaust = Path()
            exhaust.addRoundedRect(
                in: CGRect(x: 32 * scale, y: 15 * scale + yOffset, width: 4 * scale, height: 15 * scale),
                cornerSize: CGSize(width: 1 * scale, height: 1 * scale)
            )
            context.fill(exhaust, with: .color(.gray))
        }
    }
}
