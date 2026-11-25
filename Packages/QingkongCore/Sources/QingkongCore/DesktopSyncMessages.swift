import Foundation

public struct DesktopSyncRequest: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case report, preparePlayback, completePlayback }
    public let version: Int
    public let id: UUID
    public let action: Action
    public let transferID: UUID?
    public let playbackPosition: TimeInterval?
    public init(action: Action, transferID: UUID? = nil, playbackPosition: TimeInterval? = nil) {
        version = 1; id = UUID(); self.action = action; self.transferID = transferID
        self.playbackPosition = playbackPosition
    }
}

public struct DesktopSyncResponse: Codable, Sendable {
    public let version: Int
    public let id: UUID
    public let report: DesktopReport?
    public let playback: DesktopPlaybackTransfer?
    public let success: Bool
    public let error: String?
    public init(id: UUID, report: DesktopReport? = nil, playback: DesktopPlaybackTransfer? = nil,
                success: Bool = true, error: String? = nil) {
        version = 1; self.id = id; self.report = report; self.playback = playback
        self.success = success; self.error = error
    }
}

public struct DesktopPlaybackTransfer: Codable, Sendable {
    public let id: UUID
    public let track: Track
    public let onlineTrack: PublicAudioTrack?
    public let serviceAddress: String
    public let position: TimeInterval
    public let duration: TimeInterval
    public let playing: Bool
    public let volume: Float
    public let deadline: SleepDeadline?
    public let capturedAt: Date

    public init(track: Track, onlineTrack: PublicAudioTrack?, serviceAddress: String,
                position: TimeInterval, duration: TimeInterval, playing: Bool, volume: Float,
                deadline: SleepDeadline?, now: Date = .now) {
        id = UUID(); self.track = track; self.onlineTrack = onlineTrack; self.serviceAddress = serviceAddress
        self.position = position; self.duration = duration; self.playing = playing
        self.volume = volume; self.deadline = deadline; capturedAt = now
    }

    public var title: String { onlineTrack?.title ?? track.name }
    public var isValid: Bool {
        position.isFinite && position >= 0 && duration.isFinite && duration > 0 &&
        position <= duration && volume.isFinite && (0...1).contains(volume) &&
        (onlineTrack.map { PublicContentURL.isHTTPS($0.audioURL) } ?? true)
    }
}
