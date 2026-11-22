import SwiftUI
import QingkongCore

struct CompanionHistoryView: View {
    @Environment(AppServices.self) private var app
    @State private var error: String?
    var body: some View {
        List {
            Section("这台设备上的放松记录") {
                if app.companion.practices.isEmpty { Text("还没有完成的陪伴。按自己的节奏开始就好。").font(.footnote) }
                ForEach(app.companion.practices) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(record.duration.name) · \(record.mode.name)").font(.headline)
                        Text(record.completedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                        Text(record.feedback?.name ?? "未记录感受").font(.caption)
                        if let reading = record.finalHeartRate,
                           RelaxationHeartRate.latest(in: [reading], startedAt: record.startedAt, endedAt: record.completedAt) != nil {
                            Label("最后心率 \(reading.value.formatted(.number.precision(.fractionLength(0)))) 次/分", systemImage: "heart")
                                .font(.caption).accessibilityIdentifier("practice-heart-rate")
                            Text("采样 \(reading.date.formatted(.dateTime.hour().minute().second()))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }.swipeActions { Button("删除", role: .destructive) {
                        do { try app.companion.deletePractice(record.id) } catch { self.error = "暂未删除，请重试。" }
                    } }
                }
            }
            Section("这台设备上的提醒提交") {
                ForEach(app.companion.events.filter { $0.kind == .reminder }) { event in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(event.title)
                        Text(event.date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                        Text(event.detail).font(.caption)
                    }.swipeActions { Button("删除", role: .destructive) {
                        do { try app.companion.deleteEvent(event.id) } catch { self.error = "暂未删除，请重试。" }
                    } }
                }
                Text("提交不代表已收到。练习与此处提醒历史仅保存在当前设备。").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.footnote) }
        }.navigationTitle("陪伴回顾")
    }
}
