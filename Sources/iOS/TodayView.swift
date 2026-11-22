import SwiftUI
import QingkongCore

struct TodayView: View {
    @Environment(AppServices.self) private var app
    @ScaledMetric(relativeTo: .largeTitle) private var hrvFontSize = 54.0
    @Binding var selectedMood: Int
    @State private var albumID: String?
    let openMood: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                homeIntro
                NavigationLink { RelaxationView() } label: {
                    Label("陪我缓一缓", systemImage: "leaf").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                }.qingkongGlassButton(prominent: true).accessibilityIdentifier("open-relaxation")
                if !app.companion.calmHome {
                HealthAccessNote()
                hrvCard
                HStack(alignment: .top, spacing: 12) {
                    metricCard(.heartRate)
                    metricCard(.oxygen)
                }
                NavigationLink { ECGListView() } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "waveform.path.ecg.rectangle").font(.title2).foregroundStyle(app.scene.accent)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("心电图记录").font(.subheadline.weight(.medium))
                            Text(app.health.ecgs.first.map { $0.date.formatted(date: .abbreviated, time: .shortened) } ?? "暂无可读取的记录").font(.caption).foregroundStyle(Color.readableSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.readableSecondary)
                    }.padding(12)
                }.qingkongGlassButton(shape: .roundedRectangle(radius: 20))
                }
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("心情时刻").font(.title3.weight(.semibold))
                        Spacer()
                        Button("记录一下", action: openMood).font(.subheadline)
                    }
                    Text("给此刻的自己，一个温柔的回应。 ").font(.subheadline).foregroundStyle(Color.readableSecondary)
                    MoodChoices(selection: $selectedMood, onSelect: openMood)
                }
                AlbumRecommendationView(selectedAlbumID: $albumID)
                KnowledgeHighlightsView(content: app.content)
                Text("数据帮助你了解日常变化，不用于诊断疾病。 ").font(.caption).foregroundStyle(Color.readableSecondary)
                NavigationLink { CompanionTimelineView() } label: { Label("身体与心情时间线", systemImage: "clock") }
                SleepOverviewSection()
            }.padding(.horizontal, 22).padding(.bottom, 28)
        }.refreshable {
            await app.content.refresh()
            await app.health.refresh()
        }
        .task { await app.content.refresh() }
    }

    private var homeIntro: some View {
        let mood = MoodSummary.latest(in: app.store.records)?.value ?? 3
        return VStack(alignment: .leading, spacing: 10) {
            Text(Date.now.formatted(.dateTime.month().day().weekday())).font(.caption).foregroundStyle(Color.readableSecondary)
            HStack(alignment: .lastTextBaseline, spacing: 16) {
                Text("了解身体，\n也关心自己。")
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold)).tracking(-0.8)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if app.companion.calmHome {
                    Image("mood-\(mood)")
                        .resizable().scaledToFit().frame(width: 112, height: 112)
                        .id(mood)
                        .alignmentGuide(.lastTextBaseline) { $0.height * 0.86 }
                        .accessibilityLabel("心情团子")
                        .accessibilityIdentifier("today-dumpling")
                        .accessibilityValue(MoodRecord.labels[mood - 1])
                }
            }
            Text("不必时刻满分，舒服就很好。")
                .font(.subheadline).foregroundStyle(Color.readableSecondary).lineSpacing(4)
        }.padding(.top, 12).padding(.bottom, 8)
    }

    private var hrvCard: some View {
        let now = Date.now
        let calendar = Calendar.current
        let samples = app.health.readings.filter {
            $0.metric == .hrv && $0.isValid && $0.date <= now && calendar.isDate($0.date, inSameDayAs: now)
        }
        let average = HealthMath.dailyMean(samples, metric: .hrv, day: now, now: now, calendar: calendar)
        let latest = samples.max { $0.date < $1.date }
        let sources = Array(Set(samples.map(\.source))).sorted()
        return Surface {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("HRV · 今日平均", systemImage: "waveform.path.ecg").font(.subheadline.weight(.medium))
                    Spacer()
                    Text("SDNN").font(.caption).foregroundStyle(Color.readableSecondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(average.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—")
                        .font(.system(size: hrvFontSize, weight: .light, design: .rounded)).monospacedDigit()
                    Text("ms").font(.subheadline).foregroundStyle(Color.readableSecondary)
                }.foregroundStyle(app.scene.accent)
                HealthTrendChart(buckets: HealthMath.buckets(app.health.readings, metric: .hrv, period: .week), metric: .hrv, color: app.scene.accent, compact: true, selectionEnabled: false).frame(height: 66)
                    .accessibilityIdentifier("today-hrv-chart")
                VStack(alignment: .leading, spacing: 4) {
                    if let latest {
                        Text("日均依据 \(samples.count) 条有效记录")
                        Text("最近采样：\(latest.date.formatted(date: .abbreviated, time: .shortened))")
                        Text("来源：\(sources.joined(separator: "、"))")
                    } else {
                        Text("今日暂无可读取的 HRV 记录")
                    }
                }.font(.caption).foregroundStyle(Color.readableSecondary)
                if let baseline = app.health.baseline {
                    Text("个人基线 \(baseline.formatted(.number.precision(.fractionLength(0)))) ms · 此前 7 天的有效日均").font(.caption).foregroundStyle(Color.readableSecondary)
                } else {
                    Text("基线积累中 · 至少需要 3 个有效日").font(.caption).foregroundStyle(Color.readableSecondary)
                }
            }
        }
    }

    private func metricCard(_ metric: HealthMetric) -> some View {
        let latest = app.health.latest(metric)
        return Surface {
            VStack(alignment: .leading, spacing: 12) {
                Label(metric.name, systemImage: metric.symbol).font(.subheadline).foregroundStyle(app.scene.accent)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(latest.map { $0.value.formatted(.number.precision(.fractionLength(0))) } ?? "—").font(.system(.largeTitle, design: .rounded).weight(.light)).monospacedDigit()
                    Text(metric.unit).font(.caption2).foregroundStyle(Color.readableSecondary)
                }.minimumScaleFactor(0.6)
                VStack(alignment: .leading, spacing: 4) {
                    if let latest {
                        Text("采样：\(latest.date.formatted(date: .abbreviated, time: .shortened))")
                        Text("来源：\(latest.source)")
                    } else {
                        Text("暂无可读取的记录")
                    }
                }.font(.caption2).foregroundStyle(Color.readableSecondary)
            }
        }
    }
}

struct MoodChoices: View {
    @Binding var selection: Int
    var onSelect: () -> Void = {}
    var body: some View {
        GlassButtonGroup(spacing: 4) {
          HStack(alignment: .top, spacing: 5) {
            ForEach(1...5, id: \.self) { value in
                Button {
                    selection = value
                    onSelect()
                } label: {
                    VStack(spacing: 8) {
                        Image("mood-\(value)").resizable().scaledToFit().frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
                        Text(MoodRecord.labels[value - 1]).font(.caption)
                    }.padding(.vertical, 8)
                }.qingkongGlassButton(prominent: selection == value, shape: .roundedRectangle(radius: 16)).accessibilityLabel("心情：\(MoodRecord.labels[value - 1])")
                    .accessibilityAddTraits(selection == value ? .isSelected : [])
                    .accessibilityIdentifier("mood-\(value)")
            }
          }
        }
    }
}
