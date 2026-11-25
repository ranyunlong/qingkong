import Foundation
import QingkongCore

enum MacReportCache {
    struct Entry: Codable, Equatable {
        let accountScope: String
        let receivedAt: Date
        let report: DesktopReport
    }
    static var url: URL {
        URL.applicationSupportDirectory.appending(path: "QingkongMac", directoryHint: .isDirectory)
            .appending(path: "report.json")
    }

    static func validate(_ report: DesktopReport) throws -> DesktopReport {
        guard TimeZone(identifier: report.timeZoneIdentifier) != nil,
              report.generatedAt.timeIntervalSince1970.isFinite,
              report.generatedAt <= Date.now.addingTimeInterval(300),
              report.days.count <= 38,
              Set(report.days.map(\.date)).count == report.days.count else {
            throw DesktopConnectionError.invalidMessage
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: report.timeZoneIdentifier)!
        let today = calendar.startOfDay(for: report.generatedAt)
        let earliest = calendar.date(byAdding: .day, value: -37, to: today)!
        for day in report.days {
            guard day.date.timeIntervalSince1970.isFinite, day.date >= earliest, day.date <= today,
                  day.date == calendar.startOfDay(for: day.date),
                  [day.hrv, day.heartRate, day.oxygen, day.asleepSeconds].allSatisfy({ value in
                      value.map { $0.isFinite && $0 >= 0 && $0 <= 1_000_000_000 } ?? true
                  }),
                  day.oxygen.map({ $0 <= 100 }) ?? true,
                  day.asleepSeconds.map({ $0 <= 86_400 }) ?? true,
                  (0...1_000_000).contains(day.practiceCount), day.practicedSeconds.isFinite,
                  (0...1_000_000_000).contains(day.practicedSeconds),
                  day.moodCounts.allSatisfy({ (1...5).contains($0.key) && (0...1_000_000).contains($0.value) }),
                  day.stressCounts.allSatisfy({ (1...5).contains($0.key) && (0...1_000_000).contains($0.value) }) else {
                throw DesktopConnectionError.invalidMessage
            }
        }
        return report
    }

    static func load(accountScope: String, from fileURL: URL = url) throws -> Entry? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let entry = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: fileURL))
        guard !accountScope.isEmpty, entry.accountScope == accountScope else { return nil }
        _ = try validate(entry.report)
        guard entry.receivedAt.timeIntervalSince1970.isFinite,
              entry.receivedAt <= Date.now.addingTimeInterval(300) else { throw DesktopConnectionError.invalidMessage }
        return entry
    }

    static func save(_ report: DesktopReport, accountScope: String, receivedAt: Date = .now, to fileURL: URL = url) throws {
        _ = try validate(report)
        guard !accountScope.isEmpty else { throw DesktopConnectionError.invalidMessage }
        let entry = Entry(accountScope: accountScope, receivedAt: receivedAt, report: report)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entry).write(to: fileURL, options: .atomic)
    }

    static func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
