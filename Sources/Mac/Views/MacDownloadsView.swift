import SwiftUI

struct MacDownloadsView: View {
    @Bindable var downloads: AudioDownloads
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("下载与空间", systemImage: "internaldrive").font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 24) {
                storageMetric("主动下载", bytes: downloads.manualBytes, symbol: "arrow.down.circle")
                storageMetric("自动缓存", bytes: downloads.automaticBytes, symbol: "waveform")
                Spacer()
                Button("清理自动缓存", systemImage: "trash") { confirmsClear = true }
                    .disabled(downloads.automaticBytes == 0)
            }
            Toggle("仅通过 Wi-Fi 或有线网络下载", isOn: $downloads.wifiOnlyDownloads)
            if let error = downloads.storageError {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if downloads.storedRecords.isEmpty {
                ContentUnavailableView("还没有下载", systemImage: "arrow.down.circle", description: Text("在专辑中下载音轨后，可在这里管理。"))
            } else {
                List(downloads.storedRecords) { record in
                    HStack(spacing: 12) {
                        Image(systemName: record.intent == .manual ? "arrow.down.circle.fill" : "waveform").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.title ?? "已下载音轨").lineLimit(1)
                            Text(record.intent == .manual ? "主动下载" : "播放后自动缓存").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: record.byteSize, countStyle: .file))
                            .font(.callout).foregroundStyle(.secondary)
                        Button(role: .destructive) { downloads.deleteStored(identity: record.identity) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("删除\(record.title ?? "音轨")下载").accessibilityLabel("删除\(record.title ?? "音轨")下载")
                    }.padding(.vertical, 5).listRowSeparator(.hidden)
                }
                .listStyle(.inset).clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(24).frame(width: 630, height: 470)
        .confirmationDialog("清理自动缓存？", isPresented: $confirmsClear) {
            Button("清理自动缓存", role: .destructive) { downloads.clearAutomaticCache() }
        } message: { Text("主动下载的音轨和正在播放的文件会保留。") }
    }

    private func storageMetric(_ title: String, bytes: Int64, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(.title3.weight(.semibold))
        }
    }
}
