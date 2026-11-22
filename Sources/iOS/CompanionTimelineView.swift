import SwiftUI
import QingkongCore

struct CompanionTimelineView: View {
    @Environment(AppServices.self) private var app
    @State private var error: String?

    private struct Item: Identifiable {
        let id: String
        let date: Date
        let title: String
        let detail: String
        let symbol: String
        var heartRate: HealthReading? = nil
        let delete: () throws -> Void
    }

    private var items: [Item] {
        var result = app.store.entries.map { mood in
            Item(id: mood.id.uuidString, date: mood.createdAt, title: "心情：\(mood.label)",
                detail: "主动记录 · 压力 \(mood.stress)/5" + (mood.tags.isEmpty ? "" : " · " + mood.tags.map(\.name).joined(separator: "、")),
                symbol: "face.smiling", delete: { try app.store.delete(mood) })
        }
        result += app.companion.practices.map { record in
            Item(id: record.id.uuidString, date: record.completedAt, title: "\(record.duration.name) · \(record.mode.name)",
                detail: record.feedback?.name ?? "未记录感受", symbol: "leaf", heartRate: record.finalHeartRate.flatMap {
                    RelaxationHeartRate.latest(in: [$0], startedAt: record.startedAt, endedAt: record.completedAt)
                }, delete: { try app.companion.deletePractice(record.id) })
        }
        result += app.companion.events.map { event in
            Item(id: event.id, date: event.date, title: event.title, detail: event.detail,
                symbol: event.kind == .health ? "waveform.path.ecg" : "bell", delete: { try app.companion.deleteEvent(event.id) })
        }
        return result.sorted { $0.date > $1.date }
    }

    var body: some View {
        List {
            Section {
                Text("把身体与感受放在同一段时间里看看。时间接近不代表因果，也不构成诊断。提醒提交不代表已经收到。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if items.isEmpty { ContentUnavailableView("还没有时间线记录", systemImage: "clock", description: Text("记下心情或完成一次陪伴，就会从这里开始。")) }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Label(item.title, systemImage: item.symbol).font(.headline)
                    Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    Text(item.detail).font(.subheadline)
                    if let reading = item.heartRate {
                        Label("最后心率 \(reading.value.formatted(.number.precision(.fractionLength(0)))) 次/分", systemImage: "heart")
                            .font(.caption).accessibilityIdentifier("practice-heart-rate")
                        Text("采样 \(reading.date.formatted(.dateTime.hour().minute().second()))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 6)
                    .swipeActions { Button("删除", role: .destructive) {
                        do { try item.delete() } catch { self.error = "记录暂未删除，请重试。" }
                    } }
            }
        }.navigationTitle("身体与心情时间线")
            .alert("未能完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
    }
}

struct WeeklyReviewView: View {
    @Environment(AppServices.self) private var app
    @State private var weekOffset = 0
    private var week: Date {
        let start = Calendar.current.dateInterval(of: .weekOfYear, for: .now)?.start ?? Calendar.current.startOfDay(for: .now)
        return Calendar.current.date(byAdding: .weekOfYear, value: weekOffset, to: start) ?? start
    }
    var body: some View {
        let review = WeeklyCompanionReview(weekStarting: week, moods: app.store.records, practices: app.companion.practices)
        List {
            Section {
                HStack {
                    Button("上一周") { weekOffset -= 1 }
                    Spacer()
                    Text(week.formatted(.dateTime.month().day()))
                    Spacer()
                    Button("下一周") { weekOffset += 1 }.disabled(weekOffset >= 0)
                }
                Text(review.message)
                LabeledContent("有记录的天数", value: "\(review.recordedDayCount) 天")
                LabeledContent("放松陪伴", value: "\(review.practiceCount) 次 · \(Int(review.practicedSeconds / 60)) 分钟")
            }
            Section("主动记录的心情与压力") {
                ForEach(1...5, id: \.self) { level in
                    LabeledContent(MoodRecord.labels[level - 1], value: "\(review.moodDistribution[level] ?? 0) 次")
                }
                ForEach(1...5, id: \.self) { level in
                    LabeledContent("压力 \(level)/5", value: "\(review.stressDistribution[level] ?? 0) 次")
                }
            }
            Section("有数据的健康趋势") {
                Text("健康趋势依据当前已读取的最近38天记录；更早或仅部分覆盖的周不代表完整健康历史。").font(.caption).foregroundStyle(.secondary)
                ForEach(HealthMetric.allCases) { metric in
                    let end = Calendar.current.date(byAdding: .day, value: 7, to: week) ?? .now
                    let readings = app.health.readings.filter { $0.metric == metric && $0.isValid && $0.date >= week && $0.date < end && $0.date <= .now }
                    let days = Set(readings.map { Calendar.current.startOfDay(for: $0.date) })
                    let means = days.compactMap { HealthMath.dailyMean(readings, metric: metric, day: $0) }
                    if !means.isEmpty {
                        LabeledContent("\(metric.name) 日均的平均", value: "\((means.reduce(0, +) / Double(means.count)).formatted(.number.precision(.fractionLength(0...1)))) \(metric.unit)")
                        Text("依据 \(means.count) 个有采样日；缺失日期不参与计算。").font(.caption).foregroundStyle(.secondary)
                    } else { Text("\(metric.name)：本周暂无可读取记录").foregroundStyle(.secondary) }
                }
            }
            SleepReviewSection(weekStarting: week)
            Section { Text("回顾仅在本机根据记录计算，不读取日记推断疾病。记录不足时无法判断身体与心情的关联。删除源记录后会重新计算。").font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("每周回顾")
            .task(id: week) { await app.sleepHealth.refresh(weekStarting: week) }
    }
}
