import SwiftUI

struct SummaryHistoryButton: View {
    let folder: URL
    @State private var showing = false
    @State private var revisions: [SummaryHistory.Revision] = []
    @State private var readFailed = false

    var body: some View {
        Button("总结历史", systemImage: "clock.arrow.circlepath") { showing = true }
            .sheet(isPresented: $showing) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("总结历史").font(.headline)
                    Text("重新生成和编辑前会保留加密副本。可复制历史文本后在总结编辑器中恢复。")
                        .font(.caption).foregroundStyle(.secondary)
                    if readFailed { Text("历史版本读取失败，请检查存储位置。") }
                    if revisions.isEmpty && !readFailed { Text("暂无历史版本") }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(revisions) { revision in
                                DisclosureGroup {
                                    Text(verbatim: revision.text).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } label: {
                                    Text(revision.date, format: .dateTime.year().month().day().hour().minute().second())
                                }
                            }
                        }
                    }
                    HStack { Spacer(); Button("关闭") { showing = false }.keyboardShortcut(.cancelAction) }
                }.padding().frame(width: 700, height: 500)
                .task {
                    readFailed = false
                    revisions = []
                    let target = folder
                    do { revisions = try await Task.detached { try SummaryHistory.load(in: target) }.value }
                    catch { readFailed = true }
                }
            }
    }
}
