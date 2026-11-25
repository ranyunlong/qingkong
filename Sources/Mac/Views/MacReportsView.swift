import Charts
import SwiftUI
import QingkongCore

private enum MacReportRange: String, CaseIterable, Identifiable {
    case day = "日", week = "周", month = "月"
    var id: String { rawValue }
    var days: Int { switch self { case .day: 1; case .week: 7; case .month: 30 } }
}

private enum MacReportMetric: String, CaseIterable, Identifiable {
    case hrv = "HRV", heartRate = "心率", oxygen = "血氧", sleep = "睡眠"
    var id: String { rawValue }
    var unit: String { switch self { case .hrv: "毫秒"; case .heartRate: "次/分"; case .oxygen: "%"; case .sleep: "小时" } }
    var symbol: String { switch self { case .hrv: "waveform.path.ecg"; case .heartRate: "heart.fill"; case .oxygen: "drop.fill"; case .sleep: "moon.fill" } }
    var color: Color { switch self { case .hrv: .teal; case .heartRate: .pink; case .oxygen: .blue; case .sleep: .indigo } }
    func value(_ day: DesktopReportDay) -> Double? {
        switch self { case .hrv: day.hrv; case .heartRate: day.heartRate; case .oxygen: day.oxygen; case .sleep: day.asleepSeconds.map { $0 / 3600 } }
    }
}

struct MacReportsView: View {
    let connection: MacDeviceConnection
    let openDevices: () -> Void
    @State private var range: MacReportRange = .week
    @State private var metric: MacReportMetric = .hrv
    @State private var showsClearConfirmation = false
    @State private var showsInfo = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("自己的节奏").font(.largeTitle.bold())
                        if let report = connection.report {
                            Text(reportDateLabel(report)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Picker("报表范围", selection: $range) {
                        ForEach(MacReportRange.allCases) { range in Text(range.rawValue).tag(range) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 132)
                    Menu {
                        Button("报表说明", systemImage: "info.circle") { showsInfo = true }
                        Button("设备与同步", systemImage: "iphone", action: openDevices)
                        Divider()
                        Button("清除本机报表", systemImage: "trash", role: .destructive) { showsClearConfirmation = true }
                            .disabled(connection.report == nil || connection.isSyncing)
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .fixedSize().help("报表操作").accessibilityLabel("报表操作")
                }
                if let report = connection.report {
                    reportContents(report)
                } else {
                    unsyncedState
                }
                if let notice = connection.reportNotice {
                    Label(notice, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .padding(28).frame(maxWidth: 1150).frame(maxWidth: .infinity)
        }
        .confirmationDialog("清除这台 Mac 的报表缓存？", isPresented: $showsClearConfirmation) {
            Button("清除本机报表", role: .destructive) { connection.clearReport() }
        } message: { Text("手机中的记录会继续保留，重新同步可再次获取报表。") }
        .popover(isPresented: $showsInfo) {
            VStack(alignment: .leading, spacing: 12) {
                Text("关于报表").font(.headline)
                Text("按 iPhone 的时区统计。关键数字为所选范围内有数据日的日均值平均；HRV 使用 SDNN。")
                Text("空白表示没有可用数据，不补零。陪伴次数只统计已完成的记录。仅供自我观察，不用于诊断。")
                Text("自动同步需在手机上为这台 Mac 开启，并保持手机小晴空在前台。")
            }.font(.callout).padding(20).frame(width: 330)
        }
    }

    @ViewBuilder private func reportContents(_ report: DesktopReport) -> some View {
        let calendar = phoneCalendar(report)
        let days = filteredDays(report, calendar: calendar)
        HStack(spacing: 8) {
            Image(systemName: connection.isConnected ? "iphone.radiowaves.left.and.right" : "internaldrive")
            Text(connection.isConnected ? "iPhone 每日汇总" : "离线查看本机报表")
            Spacer()
            if connection.isSyncing { ProgressView().controlSize(.small) }
            Text(calendar.timeZone.identifier)
        }.font(.caption).foregroundStyle(.secondary)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
            ForEach(MacReportMetric.allCases) { item in
                metricCard(item, days: days)
            }
        }
        trendCard(days: days, calendar: calendar)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 255), spacing: 16)], spacing: 16) {
            MacDistributionCard(title: "心情", counts: counts(days, keyPath: \.moodCounts),
                                labels: ["低落", "不太好", "平静", "不错", "很好"], colors: [.indigo, .blue, .teal, .green, .orange], symbol: "face.smiling")
            MacDistributionCard(title: "压力", counts: counts(days, keyPath: \.stressCounts),
                                labels: ["很轻", "较轻", "适中", "较高", "很高"], colors: [.teal, .green, .yellow, .orange, .pink], symbol: "leaf")
        }
        companionshipCard(days: days, calendar: calendar)
    }

    private func metricCard(_ item: MacReportMetric, days: [DesktopReportDay]) -> some View {
        let values = days.compactMap(item.value)
        let mean = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        return Button { metric = item } label: {
            VStack(alignment: .leading, spacing: 12) {
                Label(item == .hrv ? "HRV · SDNN" : item.rawValue, systemImage: item.symbol)
                    .font(.callout).foregroundStyle(item.color)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(mean.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "—")
                        .font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                    if mean != nil { Text(item.unit).font(.caption).foregroundStyle(.secondary) }
                }
                Text(mean == nil ? "暂无数据" : "\(values.count) 天有记录")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(.quaternary.opacity(metric == item ? 0.8 : 0.35), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(metric == item ? item.color.opacity(0.7) : Color.clear, lineWidth: 1.5) }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain).help("查看\(item.rawValue)趋势")
        .accessibilityAddTraits(metric == item ? .isSelected : [])
    }

    private func trendCard(days: [DesktopReportDay], calendar: Calendar) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("\(metric.rawValue)趋势", systemImage: metric.symbol).font(.headline)
                Spacer()
                Text(metric.unit).font(.caption).foregroundStyle(.secondary)
            }
            if days.contains(where: { metric.value($0) != nil }) {
                Chart {
                    ForEach(Array(days.enumerated()), id: \.element.date) { index, day in
                        if let amount = metric.value(day) {
                            LineMark(x: .value("日期", day.date), y: .value(metric.unit, amount), series: .value("连续记录", segment(at: index, days: days, calendar: calendar)))
                                .foregroundStyle(metric.color.opacity(0.65)).lineStyle(StrokeStyle(lineWidth: 2))
                            PointMark(x: .value("日期", day.date), y: .value(metric.unit, amount))
                                .foregroundStyle(metric.color).symbolSize(38)
                                .accessibilityLabel("\(format(day.date, calendar: calendar))，\(amount.formatted()) \(metric.unit)")
                        }
                    }
                }
                .chartXScale(domain: chartDomain(calendar: calendar))
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: min(5, range.days))) { axis in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel { if let date = axis.as(Date.self) { Text(format(date, calendar: calendar)) } }
                    }
                }
                .chartYAxis { AxisMarks(position: .leading) }
                .frame(height: 195)
            } else {
                ContentUnavailableView("此范围暂无\(metric.rawValue)数据", systemImage: metric.symbol)
                    .frame(height: 195)
            }
        }
        .padding(20).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
    }

    private func companionshipCard(days: [DesktopReportDay], calendar: Calendar) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("安静陪伴", systemImage: "leaf.fill").font(.headline)
            HStack(alignment: .center, spacing: 28) {
                companionNumber(days.isEmpty ? "—" : "\(days.reduce(0) { $0 + $1.practiceCount })", caption: "完成次数")
                companionNumber(days.isEmpty ? "—" : "\(Int(days.reduce(0) { $0 + $1.practicedSeconds } / 60))", caption: "累计分钟")
                if days.contains(where: { $0.practiceCount > 0 }) {
                    Chart(days) { day in
                        BarMark(x: .value("日期", day.date, unit: .day), y: .value("分钟", day.practicedSeconds / 60))
                            .foregroundStyle(.teal.gradient).cornerRadius(3)
                            .accessibilityLabel("\(format(day.date, calendar: calendar))，\(Int(day.practicedSeconds / 60)) 分钟")
                    }
                    .chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 65)
                } else {
                    Spacer()
                    Image(systemName: "leaf").font(.system(size: 35, weight: .light)).foregroundStyle(.tertiary)
                }
            }
        }.padding(20).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
    }

    private func companionNumber(_ value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }.fixedSize()
    }

    private var unsyncedState: some View {
        ContentUnavailableView {
            Label("尚未同步报表", systemImage: "iphone.and.arrow.forward")
        } description: {
            Text(connection.reportSyncState == .enabled || connection.reportSyncState == .syncing ? "打开 iPhone 小晴空，等待每日汇总同步。" : "在 iPhone 上为这台 Mac 开启自动报表。")
        } actions: {
            Button("查看设备与同步", action: openDevices).buttonStyle(.borderedProminent)
        }.frame(minHeight: 330)
    }

    private func reportDateLabel(_ report: DesktopReport) -> String {
        let calendar = phoneCalendar(report)
        if let date = connection.reportReceivedAt { return "上次同步 \(format(date, calendar: calendar, includeTime: true))" }
        return "报表生成于 \(format(report.generatedAt, calendar: calendar, includeTime: true))"
    }

    private func phoneCalendar(_ report: DesktopReport) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: report.timeZoneIdentifier) ?? .gmt
        return calendar
    }

    private func filteredDays(_ report: DesktopReport, calendar: Calendar) -> [DesktopReportDay] {
        let today = calendar.startOfDay(for: .now)
        let first = calendar.date(byAdding: .day, value: -(range.days - 1), to: today) ?? today
        return report.days.filter { $0.date >= first && $0.date <= today }.sorted { $0.date < $1.date }
    }

    private func chartDomain(calendar: Calendar) -> ClosedRange<Date> {
        let today = calendar.startOfDay(for: .now)
        let first = calendar.date(byAdding: .day, value: -(range.days - 1), to: today) ?? today
        return first.addingTimeInterval(-43_200)...today.addingTimeInterval(43_200)
    }

    private func segment(at index: Int, days: [DesktopReportDay], calendar: Calendar) -> String {
        var segment = 0
        guard index > 0 else { return "0" }
        for prior in 1...index {
            let expected = calendar.date(byAdding: .day, value: 1, to: days[prior - 1].date)
            if metric.value(days[prior - 1]) == nil || expected != days[prior].date { segment += 1 }
        }
        return "\(segment)"
    }

    private func format(_ date: Date, calendar: Calendar, includeTime: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN"); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.dateFormat = includeTime ? "M月d日 HH:mm" : "M/d"
        return formatter.string(from: date)
    }

    private func counts(_ days: [DesktopReportDay], keyPath: KeyPath<DesktopReportDay, [Int: Int]>) -> [Int: Int] {
        days.reduce(into: [:]) { result, day in
            for (score, count) in day[keyPath: keyPath] { result[score, default: 0] += count }
        }
    }
}
