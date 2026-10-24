import SwiftUI
import UniformTypeIdentifiers

/// Phantom Transcode — a dedicated Vision Research .cine → ProRes/H.264/HEVC
/// converter, separate from Phantom Control (camera control). GPU debayer +
/// hardware video encode, with a batch queue. Each file owns its own state so
/// nothing bleeds between files.
@main
struct PhantomTranscodeApp: App {
    @StateObject private var model = TranscodeQueueModel()

    var body: some Scene {
        WindowGroup("Phantom Transcode") {
            TranscodeView()
                .environmentObject(model)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add .cine Files…") { openPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cine") ?? .data]
        panel.allowsMultipleSelection = true
        panel.message = "Choose Phantom .cine files to transcode"
        panel.begin { resp in
            guard resp == .OK else { return }
            Task { @MainActor in model.addFiles(panel.urls) }
        }
    }
}
