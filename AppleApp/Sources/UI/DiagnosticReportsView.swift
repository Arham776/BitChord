import SwiftUI

struct DiagnosticReportsView: View {
    @Environment(PlaybackController.self) private var controller
    @State private var report: URL?
    @State private var message: String?
    var body: some View {
        Form {
            Section {
                Text("Recent technical events stay on this device. Reports exclude credentials and private paths. Audio capture is available separately in Audio Pipeline.")
                Button("Save Diagnostic Report") {
                    do { report = try PlaybackDebugLog.shared.saveReport(snapshot: controller.diagnosticSnapshot) }
                    catch { message = error.localizedDescription }
                }
                if let report { ShareLink("Share Diagnostic Report", item: report) }
                if let message { Text(message).foregroundStyle(.red) }
            }
            Section {
                Button("Clear Diagnostic History", role: .destructive) {
                    PlaybackDebugLog.shared.clearHistory(); report = nil; message = "Diagnostic history cleared."
                }
            }
        }.navigationTitle("Diagnostic Reports")
    }
}
