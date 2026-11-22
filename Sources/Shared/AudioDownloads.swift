import Foundation
import Observation
#if !os(watchOS)
import Network
#endif
import CryptoKit
import AVFoundation
import UniformTypeIdentifiers
import QingkongCore

private func audioFileExtension(for url: URL?, mimeType: String? = nil) -> String {
    let supported = ["mp3", "m4a", "aac", "wav", "aiff", "caf", "flac", "mp4"]
    let suffix = url?.pathExtension.lowercased() ?? ""
    if supported.contains(suffix) { return suffix }
    if let mimeType, let inferred = UTType(mimeType: mimeType)?.preferredFilenameExtension,
       supported.contains(inferred) { return inferred }
    return "audio"
}

enum AudioDownloadIntent: String, Codable { case manual, automatic }
enum AudioDownloadState: Equatable {
    case unavailable, waitingForWiFi, waitingForConnection, downloading(Double), verifying, offline, failed(String)
    var label: String {
        switch self {
        case .unavailable: "尚未完整缓存"
        case .waitingForWiFi: "等待 Wi-Fi，可连接后重试"
        case .waitingForConnection: "等待允许的网络，可取消后重试"
        case .downloading(let value): "下载中 \(Int(value * 100))%"
        case .verifying: "正在校验完整文件"
        case .offline: "完整离线可用"
        case .failed(let error): "下载失败：\(error)"
        }
    }
}

private final class AudioDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let stagingDirectory: URL
    let progress: @Sendable (Int, Double) -> Void
    let completion: @Sendable (Int, URL?, String?) -> Void
    let waiting: @Sendable (Int) -> Void
    init(stagingDirectory: URL, progress: @escaping @Sendable (Int, Double) -> Void, completion: @escaping @Sendable (Int, URL?, String?) -> Void, waiting: @escaping @Sendable (Int) -> Void) {
        self.stagingDirectory = stagingDirectory; self.progress = progress; self.completion = completion; self.waiting = waiting
    }
    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) { waiting(task.taskIdentifier) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(downloadTask.taskIdentifier, totalBytesExpectedToWrite > 0 ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : 0)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse, (200...299).contains(response.statusCode),
              response.url.map(PublicContentURL.isHTTPS) == true else {
            completion(downloadTask.taskIdentifier, nil, "音源服务器未返回有效文件。")
            return
        }
        // Keep a format hint while AVFoundation inspects the complete temporary file.
        let suffix = audioFileExtension(for: downloadTask.originalRequest?.url ?? response.url, mimeType: response.mimeType)
        let target = stagingDirectory.appending(path: UUID().uuidString).appendingPathExtension(suffix)
        do {
            // URLSession removes its temporary URL after this callback returns.
            try FileManager.default.moveItem(at: location, to: target)
            completion(downloadTask.taskIdentifier, target, nil)
        } catch { completion(downloadTask.taskIdentifier, nil, "文件未能保存，可能空间不足。") }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { completion(task.taskIdentifier, nil, error.localizedDescription) }
    }
}

@MainActor @Observable
final class AudioDownloads {
    private(set) var states: [String: AudioDownloadState] = [:]
    private(set) var networkAvailable = false
    private(set) var isWiFi = false
    var wifiOnlyDownloads: Bool {
        didSet { defaults.set(wifiOnlyDownloads, forKey: "audio-wifi-only"); enforceNetworkPreference() }
    }
    private(set) var storageError: String?
    private(set) var records: [String: Record] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let manifestURL: URL
    @ObservationIgnored private let verifyFile: @Sendable (URL, Int64, String) async throws -> Bool
    #if !os(watchOS)
    @ObservationIgnored private let monitor = NWPathMonitor()
    #endif
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var tasks: [Int: (track: PublicAudioTrack, intent: AudioDownloadIntent, task: URLSessionDownloadTask)] = [:]
    @ObservationIgnored private var verifications: [String: UUID] = [:]
    @ObservationIgnored private var verifiedIdentities: Set<String> = []
    @ObservationIgnored private var playingIdentity: String?
    @ObservationIgnored private var catalog: [String: PublicAudioTrack] = [:]
    @ObservationIgnored private var catalogLoaded = false
    @ObservationIgnored private var retiredFileNames: Set<String> = []

    struct Record: Codable, Identifiable {
        var id: String { identity }
        let trackID: String
        let identity: String
        let fileName: String
        var intent: AudioDownloadIntent
        let byteSize: Int64
        let sha256: String
        var lastUsedAt: Date
        var title: String? = nil
    }

    init(testing: Bool = false, reset: Bool = false, directoryOverride: URL? = nil,
         verifyFile: @escaping @Sendable (URL, Int64, String) async throws -> Bool = { url, size, hash in
             try await Task.detached(priority: .utility) { try AudioFileIntegrity.matches(fileURL: url, byteSize: size, sha256: hash) }.value
         }) {
        self.verifyFile = verifyFile
        defaults = testing ? UserDefaults(suiteName: "QingkongAudioDownloadsUITesting")! : .standard
        if testing && reset { defaults.removePersistentDomain(forName: "QingkongAudioDownloadsUITesting") }
        wifiOnlyDownloads = defaults.object(forKey: "audio-wifi-only") as? Bool ?? true
        directory = directoryOverride ?? (testing ? URL.temporaryDirectory : URL.applicationSupportDirectory).appending(path: testing ? "QingkongAudioDownloadsUITesting" : "AudioDownloads", directoryHint: .isDirectory)
        if testing && reset && FileManager.default.fileExists(atPath: directory.path) { try? FileManager.default.removeItem(at: directory) }
        manifestURL = directory.appending(path: "manifest.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                records = try JSONDecoder().decode([String: Record].self, from: Data(contentsOf: manifestURL))
            }
            // Incomplete tasks do not survive a process restart; remove abandoned staging files.
            let known = Set(records.values.map(\.fileName)).union(["manifest.json"])
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where !known.contains(url.lastPathComponent) {
                try FileManager.default.removeItem(at: url)
            }
        } catch { storageError = "下载缓存未能读取：\(error.localizedDescription)" }
        let delegate = AudioDownloadDelegate(stagingDirectory: directory, progress: { [weak self] id, progress in
            Task { @MainActor in
                guard let self, let item = self.tasks[id] else { return }
                self.states[item.track.cacheIdentity] = .downloading(progress)
            }
        }, completion: { [weak self] id, url, error in
            Task { @MainActor in await self?.finish(taskID: id, stagedURL: url, error: error) }
        }, waiting: { [weak self] id in
            Task { @MainActor in
                guard let self, let item = self.tasks[id] else { return }
                self.states[item.track.cacheIdentity] = .waitingForConnection
            }
        })
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        #if os(watchOS)
        configuration.waitsForConnectivity = true
        #endif
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        #if !os(watchOS)
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi) && !path.isExpensive
            Task { @MainActor in
                self?.networkAvailable = available; self?.isWiFi = wifi
                self?.enforceNetworkPreference()
            }
        }
        if !testing { monitor.start(queue: DispatchQueue(label: "qingkong.audio-network")) }
        #endif
        for identity in records.keys { states[identity] = .verifying }
        Task { await verifyRestoredDownloads() }
    }

    var storedRecords: [Record] {
        records.values.sorted { ($0.lastUsedAt, $0.identity) > ($1.lastUsedAt, $1.identity) }
    }

    func storedRecord(for track: PublicAudioTrack) -> Record? { records[track.cacheIdentity] }

    var manualBytes: Int64 { records.values.filter { $0.intent == .manual }.reduce(0) { $0 + $1.byteSize } }
    var automaticBytes: Int64 { records.values.filter { $0.intent == .automatic }.reduce(0) { $0 + $1.byteSize } }

    func state(for track: PublicAudioTrack) -> AudioDownloadState {
        guard track.copyright.expiresAt.map({ $0 > .now }) ?? true else { return .failed("音轨授权已到期，请刷新曲库。") }
        guard !catalogLoaded || catalog[track.cacheIdentity] != nil else { return .unavailable }
        if localURL(for: track) != nil { return .offline }
        return states[track.cacheIdentity] ?? .unavailable
    }

    func localURL(for track: PublicAudioTrack) -> URL? {
        guard (!catalogLoaded || catalog[track.cacheIdentity] != nil),
              track.copyright.expiresAt.map({ $0 > .now }) ?? true,
              verifiedIdentities.contains(track.cacheIdentity),
              let record = records[track.cacheIdentity] else { return nil }
        let url = directory.appending(path: record.fileName)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(size) == track.byteSize else { return nil }
        return url
    }

    func playbackURL(for track: PublicAudioTrack, allowCellular: Bool) throws -> URL {
        guard !catalogLoaded || catalog[track.cacheIdentity] != nil else { throw DownloadError.message("音轨已更新或下架，请刷新曲库后重新选择。") }
        guard track.copyright.expiresAt.map({ $0 > .now }) ?? true else { throw DownloadError.message("音轨授权已到期，请刷新曲库。") }
        if let url = localURL(for: track) { return url }
        #if os(watchOS)
        throw DownloadError.message("请先在手表完整下载并校验这首音轨。手机缓存不能直接在手表离线播放。")
        #else
        guard networkAvailable else { throw DownloadError.message("当前没有网络，音轨尚未完整下载。") }
        guard isWiFi || allowCellular else { throw DownloadError.message("当前使用蜂窝网络，确认流量使用后可在线播放。") }
        guard PublicContentURL.isHTTPS(track.audioURL) else { throw DownloadError.message("音源地址无效。") }
        return track.audioURL
        #endif
    }

    func setPlayingTrack(_ track: PublicAudioTrack?) {
        playingIdentity = track?.cacheIdentity
        if let identity = playingIdentity { records[identity]?.lastUsedAt = .now }
        purgeRetiredFiles()
    }

    func automaticallyCacheAfterPlaybackStarts(_ track: PublicAudioTrack) {
        #if !os(watchOS)
        guard isWiFi else { return }
        download(track, intent: .automatic)
        #endif
    }

    func download(_ track: PublicAudioTrack, intent: AudioDownloadIntent = .manual) {
        guard !catalogLoaded || catalog[track.cacheIdentity] != nil else {
            states[track.cacheIdentity] = .failed("音轨已更新或下架，请刷新曲库后重新选择。"); return
        }
        guard track.copyright.expiresAt.map({ $0 > .now }) ?? true else {
            states[track.cacheIdentity] = .failed("音轨授权已到期，请刷新曲库。"); return
        }
        if localURL(for: track) != nil {
            if intent == .manual {
                records[track.cacheIdentity]?.intent = .manual
                records[track.cacheIdentity]?.title = track.title
                save()
            }
            return
        }
        if let running = tasks.values.first(where: { $0.track.cacheIdentity == track.cacheIdentity }) {
            if intent == .manual { tasks[running.task.taskIdentifier]?.intent = .manual }
            return
        }
        #if os(watchOS)
        guard intent == .manual else { return }
        #else
        guard networkAvailable else { states[track.cacheIdentity] = .failed("当前没有网络，请连接后重试。"); return }
        guard isWiFi || (intent == .manual && !wifiOnlyDownloads) else { states[track.cacheIdentity] = .waitingForWiFi; return }
        #endif
        guard PublicContentURL.isHTTPS(track.audioURL) else { states[track.cacheIdentity] = .failed("音源地址无效。"); return }
        if let capacity = (try? FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber)?.int64Value,
           (capacity < track.byteSize || capacity - track.byteSize < 20 * 1_024 * 1_024) {
            states[track.cacheIdentity] = .failed("可用空间不足，请清理缓存后重试。"); return
        }
        if states[track.cacheIdentity] == .verifying { return }
        var request = URLRequest(url: track.audioURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.allowsCellularAccess = intent == .manual && !wifiOnlyDownloads
        #if os(watchOS)
        request.allowsExpensiveNetworkAccess = !wifiOnlyDownloads
        request.allowsConstrainedNetworkAccess = !wifiOnlyDownloads
        #endif
        let task = session.downloadTask(with: request)
        task.countOfBytesClientExpectsToReceive = track.byteSize
        tasks[task.taskIdentifier] = (track, intent, task)
        states[track.cacheIdentity] = .downloading(0)
        task.resume()
    }

    func reconcile(with tracks: [PublicAudioTrack]) {
        catalogLoaded = true
        catalog = Dictionary(uniqueKeysWithValues: tracks.map { ($0.cacheIdentity, $0) })
        for item in tasks.values where catalog[item.track.cacheIdentity] == nil {
            item.task.cancel(); tasks.removeValue(forKey: item.task.taskIdentifier)
            states.removeValue(forKey: item.track.cacheIdentity)
        }
        for (identity, record) in records {
            if let track = catalog[identity] {
                records[identity]?.title = track.title
                continue
            }
            verifiedIdentities.remove(identity)
            if identity == playingIdentity { retiredFileNames.insert(record.fileName) }
            else if removeFile(record.fileName) {
                records.removeValue(forKey: identity)
                retiredFileNames.remove(record.fileName)
            }
        }
        for identity in states.keys where catalog[identity] == nil { states.removeValue(forKey: identity) }
        for identity in verifications.keys where catalog[identity] == nil { verifications.removeValue(forKey: identity) }
        save()
    }

    func delete(_ track: PublicAudioTrack) { deleteStored(identity: track.cacheIdentity) }

    /// Deletion uses the stored identity, including files no longer present in the public catalog.
    func deleteStored(identity: String) {
        verifications.removeValue(forKey: identity)
        for item in tasks.values where item.track.cacheIdentity == identity {
            item.task.cancel(); tasks.removeValue(forKey: item.task.taskIdentifier)
        }
        if let record = records[identity] {
            guard identity != playingIdentity else { storageError = "这首正在播放，请停止播放后再删除。"; return }
            guard removeFile(record.fileName) else { return }
            records.removeValue(forKey: identity); verifiedIdentities.remove(identity)
            retiredFileNames.remove(record.fileName)
        }
        states.removeValue(forKey: identity); save()
    }

    func clearAutomaticCache() {
        for (identity, record) in records where record.intent == .automatic && identity != playingIdentity {
            if removeFile(record.fileName) { records.removeValue(forKey: identity); states.removeValue(forKey: identity); verifiedIdentities.remove(identity) }
        }
        save()
    }

    private func enforceNetworkPreference() {
        #if os(watchOS)
        // watchOS URLSession chooses a supported route, including the paired
        // phone's proxy. A low-level path probe cannot establish that route.
        if wifiOnlyDownloads { interruptForegroundDownloads() }
        #else
        for item in tasks.values where !isWiFi && (item.intent == .automatic || wifiOnlyDownloads) {
            item.task.cancel(); tasks.removeValue(forKey: item.task.taskIdentifier)
            states[item.track.cacheIdentity] = .waitingForWiFi
        }
        #endif
    }

    func interruptForegroundDownloads() {
        for item in tasks.values {
            item.task.cancel()
            states[item.track.cacheIdentity] = .failed("下载已中断，返回后可重试。")
        }
        tasks.removeAll()
        for identity in verifications.keys { states[identity] = .failed("下载已中断，返回后可重试。") }
        verifications.removeAll()
    }

    private func finish(taskID: Int, stagedURL: URL?, error: String?) async {
        guard let item = tasks.removeValue(forKey: taskID) else {
            if let stagedURL { try? FileManager.default.removeItem(at: stagedURL) }
            return
        }
        guard let stagedURL else { states[item.track.cacheIdentity] = .failed(error ?? "文件下载未完成。"); return }
        await verifyCompletedDownload(at: stagedURL, track: item.track, intent: item.intent)
    }

    func verifyCompletedDownload(at stagedURL: URL, track: PublicAudioTrack, intent: AudioDownloadIntent) async {
        let identity = track.cacheIdentity
        let verification = UUID()
        verifications[identity] = verification
        defer { if verifications[identity] == verification { verifications.removeValue(forKey: identity) } }
        states[identity] = .verifying
        do {
            let verified = try await verifyFile(stagedURL, track.byteSize, track.sha256)
            guard verified else { throw DownloadError.message("文件大小或校验值不一致，请重试。") }
            #if os(watchOS)
            let audio = try AVAudioPlayer(contentsOf: stagedURL)
            guard audio.prepareToPlay(), audio.duration > 0 else { throw DownloadError.message("文件已下载，但无法在手表播放。") }
            #else
            let asset = AVURLAsset(url: stagedURL)
            guard try await asset.load(.isPlayable) else { throw DownloadError.message("文件已下载，但无法作为音频播放。") }
            #endif
            // A catalog refresh may withdraw or replace the track while validation runs.
            guard verifications[identity] == verification, states[identity] == .verifying,
                  (!catalogLoaded || catalog[identity] != nil) else { throw DownloadError.message("音轨已更新、下架或下载已取消，请重试。") }
            let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            let suffix = audioFileExtension(for: track.audioURL)
            let fileName = key + "." + (suffix == "audio" ? audioFileExtension(for: stagedURL) : suffix)
            let destination = directory.appending(path: fileName)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: stagedURL, to: destination)
            records[identity] = Record(trackID: track.id, identity: identity, fileName: fileName, intent: intent, byteSize: track.byteSize, sha256: track.sha256, lastUsedAt: .now, title: track.title)
            verifiedIdentities.insert(identity)
            states[identity] = .offline
            save()
            trimAutomaticCache()
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            if verifications[identity] == verification { states[identity] = .failed(error.localizedDescription) }
        }
    }

    private func verifyRestoredDownloads() async {
        // A persisted index alone cannot prove that a file is still complete after relaunch.
        for record in records.values {
            let url = directory.appending(path: record.fileName)
            let valid = (try? await Task.detached(priority: .utility) {
                try AudioFileIntegrity.matches(fileURL: url, byteSize: record.byteSize, sha256: record.sha256)
            }.value) == true
            guard records[record.identity]?.fileName == record.fileName else { continue }
            if valid && (!catalogLoaded || catalog[record.identity] != nil) {
                verifiedIdentities.insert(record.identity)
                states[record.identity] = .offline
            } else {
                verifiedIdentities.remove(record.identity)
                if record.identity == playingIdentity { retiredFileNames.insert(record.fileName) }
                else if removeFile(record.fileName) { records.removeValue(forKey: record.identity) }
                states[record.identity] = .failed("缓存文件已失效或校验失败，请重新下载或清理。")
            }
        }
        save()
    }

    private func trimAutomaticCache() {
        var bytes = automaticBytes
        let limit: Int64 = 300 * 1_024 * 1_024
        for record in records.values.filter({ $0.intent == .automatic && $0.identity != playingIdentity }).sorted(by: { $0.lastUsedAt < $1.lastUsedAt }) where bytes > limit {
            if removeFile(record.fileName) { records.removeValue(forKey: record.identity); states.removeValue(forKey: record.identity); verifiedIdentities.remove(record.identity); bytes -= record.byteSize }
        }
        save()
    }

    @discardableResult private func removeFile(_ name: String) -> Bool {
        do {
            let url = directory.appending(path: name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return true
        } catch { storageError = "缓存文件未能删除：\(error.localizedDescription)"; return false }
    }
    private func purgeRetiredFiles() {
        let activeName = playingIdentity.flatMap { records[$0]?.fileName }
        for name in retiredFileNames where name != activeName {
            if removeFile(name) {
                retiredFileNames.remove(name)
                for (identity, record) in records where record.fileName == name {
                    records.removeValue(forKey: identity)
                    verifiedIdentities.remove(identity)
                    states.removeValue(forKey: identity)
                }
            }
        }
        save()
    }
    private func save() {
        do { try JSONEncoder().encode(records).write(to: manifestURL, options: .atomic) }
        catch { storageError = "缓存索引保存失败：\(error.localizedDescription)" }
    }
    private enum DownloadError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let message) = self { message } else { nil } }
    }
}
