import Foundation

public enum PhoneAirPlay {
    public static let capability = "phone-airplay-v1"

    /// Some long-form routes expose only "AirPlay". Mirror to a sole trusted
    /// connection in that case; this selects a display, never an audio output.
    public static func matchingReceiver(_ routeName: String, receivers: [String: String]) -> String? {
        guard !routeName.isEmpty else { return nil }
        if routeName == "AirPlay" {
            return receivers.count == 1 ? receivers.keys.first : nil
        }
        let matches = receivers.filter { $0.value == routeName }
        return matches.count == 1 ? matches.first?.key : nil
    }
}

public struct PhonePlaybackUpdate: Codable, Equatable, Sendable {
    public var routeName: String
    public var snapshot: DesktopPlaybackSnapshot
    public init(routeName: String, snapshot: DesktopPlaybackSnapshot) {
        self.routeName = routeName; self.snapshot = snapshot
    }
    public var isValid: Bool {
        !routeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && routeName.count <= 200 &&
            !snapshot.deviceName.isEmpty && snapshot.deviceName.count <= 100 && snapshot.isValid
    }
}

/// Controls the iPhone decoder. They never start a second decoder on the receiver.
public struct PhonePlaybackCommand: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case status, play, pause, previous, next, select, seek, volume, mode, timer, stop, release
    }
    public var id: UUID
    public var sessionID: UUID
    public var action: Action
    public var amount: Double?
    public var mode: AudioPlaybackMode?
    public var deadline: SleepDeadline?
    public init(id: UUID = UUID(), sessionID: UUID, action: Action, amount: Double? = nil,
                mode: AudioPlaybackMode? = nil, deadline: SleepDeadline? = nil) {
        self.id = id; self.sessionID = sessionID; self.action = action
        self.amount = amount; self.mode = mode; self.deadline = deadline
    }
    public var isValid: Bool {
        switch action {
        case .select:
            guard let amount else { return false }
            return amount.isFinite && (0..<1000).contains(amount) && amount.rounded(.down) == amount && mode == nil && deadline == nil
        case .seek:
            return amount.map { $0.isFinite && $0 >= 0 } == true && mode == nil && deadline == nil
        case .volume:
            return amount.map { $0.isFinite && (0...1).contains($0) } == true && mode == nil && deadline == nil
        case .mode: return mode != nil && amount == nil && deadline == nil
        case .timer:
            return amount == nil && mode == nil && (deadline.map {
                $0.date.timeIntervalSince1970.isFinite && ($0.durationMinutes.map { (0...120).contains($0) } ?? true)
            } ?? true)
        default: return amount == nil && mode == nil && deadline == nil
        }
    }
}

public struct PhonePlaybackReply: Codable, Equatable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var snapshot: DesktopPlaybackSnapshot?
    public var error: String?
    public init(id: UUID, sessionID: UUID, snapshot: DesktopPlaybackSnapshot? = nil, error: String? = nil) {
        self.id = id; self.sessionID = sessionID; self.snapshot = snapshot; self.error = error
    }
    public var success: Bool { error == nil && snapshot?.isValid == true && snapshot?.sessionID == sessionID }
}
