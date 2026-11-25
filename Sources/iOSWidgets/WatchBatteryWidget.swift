import SwiftUI
import WidgetKit
import QingkongCore

struct WatchBatteryEntry: TimelineEntry {
    let date: Date
    let battery: WatchBatterySnapshot?
}

struct WatchBatteryProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchBatteryEntry { .init(date: .now, battery: nil) }
    func getSnapshot(in context: Context, completion: @escaping (WatchBatteryEntry) -> Void) {
        completion(.init(date: .now, battery: WatchBatteryStorage.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchBatteryEntry>) -> Void) {
        let now = Date.now
        let battery = WatchBatteryStorage.load()
        var entries = [WatchBatteryEntry(date: now, battery: battery)]
        if let battery, battery.percentage(at: now) != nil {
            entries.append(.init(date: battery.sampledAt.addingTimeInterval(WatchBatterySnapshot.maximumAge), battery: battery))
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

struct WatchBatteryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WatchBatteryStorage.kind, provider: WatchBatteryProvider()) { entry in
            let percentage = entry.battery?.percentage(at: entry.date)
            GeometryReader { geometry in
                let size = min(geometry.size.width, geometry.size.height)
                ZStack {
                    Circle().stroke(.primary.opacity(0.2), lineWidth: 5)
                    if let battery = entry.battery, percentage != nil {
                        Circle().trim(from: 0, to: battery.level)
                            .stroke(.primary, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        if battery.charging {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: size * 0.24, weight: .bold))
                                .padding(2)
                                .background(.background, in: Circle())
                                .offset(y: size * 0.32)
                        }
                    }
                }
                .padding(4)
                .frame(width: size, height: size)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .containerBackground(.clear, for: .widget)
            .widgetURL(URL(string: "qingkong://watch-battery"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(percentage.map { "Apple Watch 电量 \($0)%，\(entry.battery?.charging == true ? "正在充电，" : "")读数来自" + (entry.battery?.sampledAt.formatted(date: .abbreviated, time: .shortened) ?? "") } ?? "手表电量尚未同步或已过期，请打开两端的小晴空更新")
        }
        .configurationDisplayName("手表电量")
        .description("用圆环显示最近同步的手表电量，充电时显示闪电。需安装并打开手表端；30 分钟未更新显示空环，刷新时间由系统安排。")
        .supportedFamilies([.accessoryCircular])
    }
}
