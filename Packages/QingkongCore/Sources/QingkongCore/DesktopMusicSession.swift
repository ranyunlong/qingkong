import Foundation

public enum AudioPlaybackMode: String, Codable, CaseIterable, Sendable {
    case single, sequence, shuffle
    public var title: String {
        switch self { case .single: "单曲循环"; case .sequence: "顺序循环"; case .shuffle: "随机循环" }
    }
    public var symbol: String {
        switch self { case .single: "repeat.1"; case .sequence: "repeat"; case .shuffle: "shuffle" }
    }
}

public struct DesktopQueueItem: Codable, Equatable, Sendable, Identifiable {
    public let track: Track?
    public let onlineTrack: PublicAudioTrack?

    public init(track: Track) { self.track = track; onlineTrack = nil }
    public init(onlineTrack: PublicAudioTrack) { track = nil; self.onlineTrack = onlineTrack }

    public var id: String {
        if let track { return "builtin:\(track.rawValue)" }
        return "online:\(onlineTrack?.id ?? "")"
    }
    public var title: String { onlineTrack?.title ?? track?.name ?? "" }
    public var isValid: Bool {
        if track != nil { return onlineTrack == nil }
        guard let onlineTrack else { return false }
        return !onlineTrack.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            PublicContentURL.isHTTPS(onlineTrack.audioURL)
    }
}

public struct DesktopPlaybackStart: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var queue: [DesktopQueueItem]
    public var index: Int
    public var position: TimeInterval
    public var playing: Bool
    public var mode: AudioPlaybackMode
    public var deadline: SleepDeadline?
    public var serviceAddress: String

    public init(sessionID: UUID = UUID(), queue: [DesktopQueueItem], index: Int,
                position: TimeInterval, playing: Bool, mode: AudioPlaybackMode,
                deadline: SleepDeadline?, serviceAddress: String) {
        self.sessionID = sessionID; self.queue = queue; self.index = index; self.position = position
        self.playing = playing; self.mode = mode; self.deadline = deadline; self.serviceAddress = serviceAddress
    }

    public var isValid: Bool {
        validDesktopQueue(queue, index: index) && position.isFinite && position >= 0 &&
            validDesktopDeadline(deadline) &&
            (!queue.contains(where: { $0.onlineTrack != nil }) ||
             (try? PublicContentURL.snapshotURL(from: serviceAddress)) != nil)
    }
}

public struct DesktopPlaybackSnapshot: Codable, Equatable, Sendable {
    public var sessionID: UUID
    public var revision: UInt64
    public var queue: [DesktopQueueItem]
    public var index: Int
    public var position: TimeInterval
    public var duration: TimeInterval
    public var playing: Bool
    public var buffering: Bool
    public var mode: AudioPlaybackMode
    public var volume: Float
    public var deadline: SleepDeadline?
    public var sampledAt: Date
    public var deviceName: String

    public init(sessionID: UUID, revision: UInt64, queue: [DesktopQueueItem], index: Int,
                position: TimeInterval, duration: TimeInterval, playing: Bool, buffering: Bool = false,
                mode: AudioPlaybackMode, volume: Float, deadline: SleepDeadline?,
                sampledAt: Date = .now, deviceName: String = "Mac") {
        self.sessionID = sessionID; self.revision = revision; self.queue = queue; self.index = index
        self.position = position; self.duration = duration; self.playing = playing; self.buffering = buffering
        self.mode = mode; self.volume = volume; self.deadline = deadline
        self.sampledAt = sampledAt; self.deviceName = deviceName
    }

    public var isValid: Bool {
        validDesktopQueue(queue, index: index) && position.isFinite && position >= 0 &&
            duration.isFinite && duration >= 0 && position <= duration &&
            volume.isFinite && (0...1).contains(volume) && validDesktopDeadline(deadline) &&
            sampledAt.timeIntervalSince1970.isFinite
    }

    public var currentItem: DesktopQueueItem? { queue.indices.contains(index) ? queue[index] : nil }

    /// Use only the receiving device's clock; sampledAt may come from a differently set Mac clock.
    public func projectedPosition(at now: Date, receivedAt: Date, connected: Bool) -> TimeInterval {
        let limit = duration.isFinite ? max(0, duration) : 0
        let base = position.isFinite ? min(limit, max(0, position)) : 0
        guard connected, playing, !buffering else { return base }
        let elapsed = now.timeIntervalSince(receivedAt)
        guard elapsed.isFinite else { return base }
        return min(limit, base + min(3, max(0, elapsed)))
    }
}

public struct DesktopPlaybackCommand: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case status, play, pause, previous, next, seek, volume, mode, timer, release
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
        case .seek:
            guard let amount else { return false }
            return amount.isFinite && amount >= 0 && mode == nil && deadline == nil
        case .volume:
            guard let amount else { return false }
            return amount.isFinite && (0...1).contains(amount) && mode == nil && deadline == nil
        case .mode:
            return mode != nil && amount == nil && deadline == nil
        case .timer:
            return amount == nil && mode == nil && validDesktopDeadline(deadline)
        case .status, .play, .pause, .previous, .next, .release:
            return amount == nil && mode == nil && deadline == nil
        }
    }
}

public struct DesktopMusicRequest: Codable, Sendable {
    public enum Action: String, Codable, Sendable {
        case hello, prepare, commit, command, reportUpload, observe, reportSyncStatus
        case catalogBegin, catalogChunk, catalogCommit, catalogStatus
        case phonePlayback, phonePlaybackEnd, phoneCommandResult
    }
    public var version = 2
    public var id: UUID
    public var action: Action
    public var start: DesktopPlaybackStart?
    public var command: DesktopPlaybackCommand?
    public var sessionID: UUID?
    public var report: DesktopReport?
    public var deviceID: String?
    public var deviceName: String?
    public var observing: Bool?
    public var reportSyncState: DesktopReportSyncState?
    public var catalogTransfer: DesktopMusicCatalogTransferInfo?
    public var catalogChunk: DesktopMusicCatalogChunk?
    public var catalogTransferID: UUID?
    public var capabilities: [String]?
    public var phonePlayback: PhonePlaybackUpdate?
    public var phoneReply: PhonePlaybackReply?

    public init(action: Action, id: UUID = UUID(), start: DesktopPlaybackStart? = nil,
                command: DesktopPlaybackCommand? = nil, sessionID: UUID? = nil,
                report: DesktopReport? = nil, deviceID: String? = nil, deviceName: String? = nil,
                observing: Bool? = nil, reportSyncState: DesktopReportSyncState? = nil,
                catalogTransfer: DesktopMusicCatalogTransferInfo? = nil,
                catalogChunk: DesktopMusicCatalogChunk? = nil, catalogTransferID: UUID? = nil,
                capabilities: [String]? = nil, phonePlayback: PhonePlaybackUpdate? = nil,
                phoneReply: PhonePlaybackReply? = nil) {
        self.action = action; self.id = id; self.start = start; self.command = command
        self.sessionID = sessionID; self.report = report; self.deviceID = deviceID; self.deviceName = deviceName
        self.observing = observing; self.reportSyncState = reportSyncState
        self.catalogTransfer = catalogTransfer; self.catalogChunk = catalogChunk; self.catalogTransferID = catalogTransferID
        self.capabilities = capabilities
        self.phonePlayback = phonePlayback; self.phoneReply = phoneReply
    }
}

public struct DesktopMusicResponse: Codable, Sendable {
    public var version = 2
    public var id: UUID
    public var success: Bool
    public var error: String?
    public var snapshot: DesktopPlaybackSnapshot?
    public var preparedID: UUID?
    public var resumeOnRelease: Bool?
    public var hostID: UUID?
    public var capabilities: [String]?
    public var catalogStatus: DesktopMusicCatalogStatus?
    public var catalogReceipt: DesktopMusicCatalogTransferInfo?
    public var airPlayReceiverName: String?
    public var phoneCommand: PhonePlaybackCommand?

    public init(id: UUID, success: Bool = true, error: String? = nil,
                snapshot: DesktopPlaybackSnapshot? = nil, preparedID: UUID? = nil,
                resumeOnRelease: Bool? = nil, hostID: UUID? = nil, capabilities: [String]? = nil,
                catalogStatus: DesktopMusicCatalogStatus? = nil, catalogReceipt: DesktopMusicCatalogTransferInfo? = nil,
                airPlayReceiverName: String? = nil, phoneCommand: PhonePlaybackCommand? = nil) {
        self.id = id; self.success = success; self.error = error
        self.snapshot = snapshot; self.preparedID = preparedID
        self.resumeOnRelease = resumeOnRelease; self.hostID = hostID; self.capabilities = capabilities
        self.catalogStatus = catalogStatus; self.catalogReceipt = catalogReceipt
        self.airPlayReceiverName = airPlayReceiverName; self.phoneCommand = phoneCommand
    }
}

private func validDesktopQueue(_ queue: [DesktopQueueItem], index: Int) -> Bool {
    (1...1000).contains(queue.count) && queue.indices.contains(index) && queue.allSatisfy(\.isValid)
}

private func validDesktopDeadline(_ deadline: SleepDeadline?) -> Bool {
    guard let deadline else { return true }
    return deadline.date.timeIntervalSince1970.isFinite && (deadline.durationMinutes.map { $0 >= 0 } ?? true)
}
