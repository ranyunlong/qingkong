import SwiftUI
import Charts
import HealthKit
import QingkongCore

struct TrendsView: View {
    @Environment(AppServices.self) private var app
    @ScaledMetric(relativeTo: .largeTitle) private var readingFontSize = 44.0
    @State private var metric: HealthMetric = .hrv
    @State private var period: TrendPeriod = .week
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageIntro(eyebrow: "身体的长期日记", title: "看见变化，\n找到自己的节奏。", subtitle: "比起一个数字，更值得了解的是自己的日常。")
                HealthAccessNote()
                Picker("健康指标", selection: $metric) {
                    ForEach(HealthMetric.allCases) { Text($0.name).tag($0) }
                }.pickerStyle(.segmented)
                Surface {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(metric.name).font(.headline)
                            Spacer()
                            Text(metric == .hrv ? "SDNN · ms" : metric.unit).font(.caption).foregroundStyle(Color.readableSecondary)
                        }
                        if let latest = app.health.latest(metric) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(latest.value.formatted(.number.precision(.fractionLength(0)))).font(.system(size: readingFontSize, weight: .light, design: .rounded)).foregroundStyle(app.scene.accent)
                                Text("最近一次").font(.caption).foregroundStyle(Color.readableSecondary)
                            }
                        } else { Text("—").font(.largeTitle).foregroundStyle(Color.readableSecondary) }
                        Picker("时间范围", selection: $period) { ForEach(TrendPeriod.allCases) { Text($0.name).tag($0) } }.pickerStyle(.segmented)
                        HealthTrendChart(buckets: HealthMath.buckets(app.health.readings, metric: metric, period: period), color: app.scene.accent).frame(height: 210)
                        Text("曲线按时间段取平均；空缺表示没有记录，不代表数值为零。 ").font(.caption).foregroundStyle(Color.readableSecondary)
                    }
                }
                if let latest = app.health.latest(metric) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(latest.source, systemImage: "applewatch").font(.subheadline)
                        Text("最近采样：\(latest.date.formatted(date: .complete, time: .shortened))").font(.caption).foregroundStyle(Color.readableSecondary)
                    }
                }
                if metric == .hrv {
                    Surface {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("与自己的基线比较").font(.headline)
                            if let baseline = app.health.baseline {
                                Text("个人基线 \(baseline.formatted(.number.precision(.fractionLength(0)))) ms").foregroundStyle(app.scene.accent)
                                if let today = app.health.dailyHRV {
                                    Text("今日日均 \(today.formatted(.number.precision(.fractionLength(0)))) ms，较基线\(today >= baseline ? "高" : "低") \((abs(today - baseline) / baseline * 100).formatted(.number.precision(.fractionLength(0))))%。").font(.subheadline)
                                }
                            } else { Text("基线积累中").foregroundStyle(app.scene.accent) }
                            Text("此前 7 个日历日中，至少有 3 个有效日，才显示日均值的平均水平。HRV 受多种因素影响，不用于判断疾病或直接判定情绪。 ").font(.caption).foregroundStyle(Color.readableSecondary).lineSpacing(4)
                        }
                    }
                }
                NavigationLink { ECGListView() } label: { Label("查看心电图记录", systemImage: "waveform.path.ecg.rectangle") }
            }.padding(.horizontal, 22).padding(.bottom, 28)
        }.refreshable { await app.health.refresh() }
    }
}

struct ECGListView: View {
    @Environment(AppServices.self) private var app
    var body: some View {
        List {
            Section {
                Text("显示「健康」中已有的心电图记录和系统分类。晴空不主动测量或诊断。 ").font(.footnote).foregroundStyle(Color.readableSecondary)
            }
            if app.health.ecgs.isEmpty {
                ContentUnavailableView("暂无心电图记录", systemImage: "waveform.path.ecg", description: Text("记录可用性取决于设备、地区及你允许读取的数据。"))
            }
            ForEach(app.health.ecgs) { record in
                NavigationLink {
                    ECGDetailView(record: record)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.classification).font(.headline)
                        Text(record.date.formatted(date: .abbreviated, time: .shortened)).font(.subheadline).foregroundStyle(Color.readableSecondary)
                        Text(record.source).font(.caption).foregroundStyle(Color.readableSecondary)
                    }.padding(.vertical, 4)
                }
            }
        }.navigationTitle("心电图记录").refreshable { await app.health.refresh() }
    }
}

struct ECGDetailView: View {
    @Environment(AppServices.self) private var app
    let record: ECGRecord
    @State private var points: [VoltagePoint] = []
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(record.date.formatted(date: .complete, time: .shortened)).font(.subheadline).foregroundStyle(Color.readableSecondary)
                Text(record.classification).font(.title2.weight(.semibold))
                Text("以上为健康记录中的系统分类，非晴空的诊断结论。 ").font(.footnote).foregroundStyle(Color.readableSecondary)
                if loading { ProgressView("正在读取波形").frame(maxWidth: .infinity) }
                else if !points.isEmpty {
                    Chart(points) { point in
                        LineMark(x: .value("秒", point.seconds), y: .value("mV", point.millivolts)).foregroundStyle(app.scene.accent).lineStyle(StrokeStyle(lineWidth: 1))
                    }.frame(height: 240).chartScrollableAxes(.horizontal).chartXVisibleDomain(length: 5)
                        .chartXAxisLabel("秒").chartYAxisLabel("mV").accessibilityLabel("心电图电压波形，横向滑动查看")
                } else { ContentUnavailableView("暂无可读取的波形", systemImage: "waveform.path.ecg") }
                if let error { Text(error).font(.footnote).foregroundStyle(Color.readableSecondary); Button("重新读取") { Task { await load() } } }
                LabeledContent("记录时长", value: "\(record.sample.endDate.timeIntervalSince(record.sample.startDate).formatted(.number.precision(.fractionLength(0)))) 秒")
                LabeledContent("来源", value: record.source)
                if let heartRate = record.sample.averageHeartRate {
                    LabeledContent("平均心率", value: "\(heartRate.doubleValue(for: .count().unitDivided(by: .minute())).formatted(.number.precision(.fractionLength(0)))) 次/分")
                }
            }.padding(22)
        }.navigationTitle("记录详情").task { await load() }
    }
    private func load() async {
        loading = true; error = nil
        do { points = try await app.health.waveform(for: record) }
        catch { self.error = "波形暂时无法读取，请重试。" }
        loading = false
    }
}
