import SwiftUI

struct DiagnosticsView: View {
    @State private var snapshot: DiagnosticLogSnapshot?
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("日志只保存在本机，不含拍摄画面或录音，不会自动上传。点击右上角“导出”，可以发送给开发者或存储到“文件”。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let failure {
                    Text("无法读取诊断日志：\(failure)").foregroundStyle(.red)
                } else if let snapshot {
                    Text(snapshot.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                } else {
                    ProgressView("正在读取日志…")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .navigationTitle("诊断日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("刷新") { Task { await reload() } }
                if let snapshot { ShareLink("导出", item: snapshot.fileURL) }
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
