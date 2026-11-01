import SwiftUI

struct DiagnosticsView: View {
    @State private var snapshot: DiagnosticLogSnapshot?
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.string("diagnostics.privacy"))
                    .font(.footnote).foregroundStyle(.secondary)
                if let failure {
                    Text(L10n.format("diagnostics.read_error", failure)).foregroundStyle(.red)
                } else if let snapshot {
                    Text(snapshot.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                } else {
                    ProgressView(L10n.string("diagnostics.loading"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .navigationTitle(L10n.string("diagnostics.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(L10n.string("action.refresh")) { Task { await reload() } }
                if let snapshot { ShareLink(L10n.string("action.export"), item: snapshot.fileURL) }
            }
        }
        .task { await reload() }
    }

    @MainActor
    private func reload() async {
        failure = nil
        do {
            snapshot = try await DebugLog.shared.snapshot()
        } catch {
            snapshot = nil
            failure = error.localizedDescription
        }
    }
}
