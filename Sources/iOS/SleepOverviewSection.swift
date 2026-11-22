import SwiftUI
import QingkongCore

struct SleepOverviewSection: View {
    @Environment(AppServices.self) private var app
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("昨晚睡眠", systemImage: "bed.double").font(.headline)
            if let night = SleepSummaryMath.night(samples: app.sleepHealth.samples, endingOn: .now) {
                Text(sleepDuration(night.asleepSeconds)).font(.title2.monospacedDigit())
                Text("来源：\(night.sources.sorted().joined(separator: "、")) · 最近采样 \(night.latestSampleEnd.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("暂无可读取的昨晚睡眠记录").foregroundStyle(.secondary)
            }
            if !app.sleepHealth.requested {
                Button("允许读取睡眠记录") { Task { await app.sleepHealth.authorize() } }.disabled(app.sleepHealth.loading)
            } else {
                Button("刷新睡眠记录") { Task { await app.sleepHealth.refresh() } }.disabled(app.sleepHealth.loading)
            }
            if let error = app.sleepHealth.error { Text(error).font(.footnote) }
            Text("单独授权，只读不写。依据昨晚18:00至今天12:00窗口的实际睡眠记录，重叠采样去重；无记录不估算，不生成睡眠评分。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 8)
    }
}

struct SleepReviewSection: View {
    @Environment(AppServices.self) private var app
    let weekStarting: Date
    var body: some View {
        Section("睡眠记录") {
            if let review = SleepSummaryMath.week(samples: app.sleepHealth.samples, weekStarting: weekStarting) {
                LabeledContent("有记录的夜数", value: "\(review.recordedNightCount) 夜")
                LabeledContent("实际记录的平均睡眠", value: sleepDuration(review.averageAsleepSeconds))
                Text("只按有数据的夜晚计算，缺失日期不补值。数据来自你允许读取的 Apple 健康记录。").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("所选这一周暂无可读取的睡眠记录，不估算或补值。").foregroundStyle(.secondary)
            }
            if !app.sleepHealth.requested {
                Button("允许读取睡眠记录") { Task { await app.sleepHealth.authorize(weekStarting: weekStarting) } }.disabled(app.sleepHealth.loading)
            } else {
                Button("刷新本周睡眠记录") { Task { await app.sleepHealth.refresh(weekStarting: weekStarting) } }.disabled(app.sleepHealth.loading)
            }
            if let error = app.sleepHealth.error { Text(error).font(.footnote) }
        }
    }
}

private func sleepDuration(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    return "\(minutes / 60) 小时 \(minutes % 60) 分钟"
}
