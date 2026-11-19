import SwiftUI
import QingkongCore

struct TodayView: View {
    @Environment(AppServices.self) private var app
    @ScaledMetric(relativeTo: .largeTitle) private var hrvFontSize = 54.0
    @Binding var selectedMood: Int
    let openMood: () -> Void
    let openSleep: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageIntro(eyebrow: Date.now.formatted(.dateTime.month().day().weekday()), title: "了解身体，\n也关心自己。", subtitle: "不必时刻满分，舒服就很好。")
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
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("心情时刻").font(.title3.weight(.semibold))
                        Spacer()
                        Button("记录一下", action: openMood).font(.subheadline)
                    }
                    Text("给此刻的自己，一个温柔的回应。 ").font(.subheadline).foregroundStyle(Color.readableSecondary)
                    MoodChoices(selection: $selectedMood, onSelect: openMood)
                }
                Button(action: openSleep) {
                    ZStack(alignment: .bottomLeading) {
                        Image(app.scene == .clear ? "forest" : app.scene.image).resizable().scaledToFill().frame(height: 180).clipped()
                        LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                        HStack(alignment: .bottom) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("给自己一段安静").font(.caption)
                                Text("慢下来，听见自然。").font(.title3.weight(.semibold))
                                Text("离线自然声音 · 轻柔陪伴").font(.caption)
                            }
                            Spacer()
                            Image(systemName: "play.fill").font(.title3).padding(14).background(.white.opacity(0.2), in: Circle())
                        }.foregroundStyle(.white).padding(20)
                    }.clipShape(RoundedRectangle(cornerRadius: 24))
                }.qingkongGlassButton(shape: .roundedRectangle(radius: 24)).accessibilityLabel("进入助眠，听自然声音")
                Text("数据帮助你了解日常变化，不用于诊断疾病。 ").font(.caption).foregroundStyle(Color.readableSecondary)
            }.padding(.horizontal, 22).padding(.bottom, 28)
        }.refreshable { await app.health.refresh() }
    }

    private var hrvCard: some View {
        Surface {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("HRV · 今日平均", systemImage: "waveform.path.ecg").font(.subheadline.weight(.medium))
                    Spacer()
                    Text("SDNN").font(.caption).foregroundStyle(Color.readableSecondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(app.health.dailyHRV.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—")
                        .font(.system(size: hrvFontSize, weight: .light, design: .rounded)).monospacedDigit()
                    Text("ms").font(.subheadline).foregroundStyle(Color.readableSecondary)
                }.foregroundStyle(app.scene.accent)
                HealthTrendChart(buckets: HealthMath.buckets(app.health.readings, metric: .hrv, period: .week), color: app.scene.accent, compact: true).frame(height: 66)
                if let baseline = app.health.baseline {
                    Text("个人基线 \(baseline.formatted(.number.precision(.fractionLength(0)))) ms · 此前 7 天的有效日均").font(.caption).foregroundStyle(Color.readableSecondary)
                } else {
                    Text("基线积累中 · 至少需要 3 个有效日").font(.caption).foregroundStyle(Color.readableSecondary)
                }
            }
        }
    }

    private func metricCard(_ metric: HealthMetric) -> some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                Label(metric.name, systemImage: metric.symbol).font(.subheadline).foregroundStyle(app.scene.accent)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(app.health.latest(metric).map { $0.value.formatted(.number.precision(.fractionLength(0))) } ?? "—").font(.system(.largeTitle, design: .rounded).weight(.light)).monospacedDigit()
                    Text(metric.unit).font(.caption2).foregroundStyle(Color.readableSecondary)
                }.minimumScaleFactor(0.6)
                Text(app.health.latest(metric).map { $0.date.formatted(date: .abbreviated, time: .shortened) } ?? "暂无记录").font(.caption2).foregroundStyle(Color.readableSecondary)
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
