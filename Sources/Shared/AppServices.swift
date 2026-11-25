import Foundation
import Observation
import QingkongCore
import WidgetKit

@MainActor @Observable
final class AppServices {
    let store: LocalStore
    let health: HealthService
    let player: AudioPlayer
    let link: Connectivity
    let companion: CompanionStore
    let content: ContentLibrary
    let downloads: AudioDownloads
    #if os(watchOS)
    let watchReminders: WatchHealthReminderService
    #endif
    #if os(iOS)
    let reminders: RelaxationReminderService
    let sleepHealth: SleepHealthService
    let desktopSync: PhoneDesktopSync
    var musicWidgetError: String?
    var healthIntroductionActive = false
    var needsHealthIntroduction: Bool {
        (!testing || ProcessInfo.processInfo.arguments.contains("--ui-health-introduction")) && !health.isDemo && health.needsConnectionIntroduction
    }
    #endif
    var snapshotError: String?
    private(set) var today = Date.now
    @ObservationIgnored private let testing: Bool

    var scene: SceneTheme { store.preferences.scene(entries: store.records, now: today) }

    init() throws {
        let args = ProcessInfo.processInfo.arguments
        #if DEBUG
        testing = args.contains("--ui-testing")
        #else
        testing = false
        #endif
        store = try LocalStore(testing: testing, reset: args.contains("--ui-reset"))
        companion = try CompanionStore(testing: testing, reset: args.contains("--ui-reset"))
        health = HealthService(testing: testing, demo: args.contains("--demo-health"))
        content = ContentLibrary(testing: testing, reset: args.contains("--ui-reset"))
        downloads = AudioDownloads(testing: testing, reset: args.contains("--ui-reset"))
        #if os(watchOS)
        watchReminders = WatchHealthReminderService(disabled: testing || health.isDemo)
        #endif
        #if os(iOS)
        reminders = RelaxationReminderService(disabledForTesting: testing || health.isDemo)
        sleepHealth = SleepHealthService(testing: testing)
        #endif
        player = AudioPlayer()
        link = Connectivity(store: store, player: player)
        #if os(iOS)
        desktopSync = PhoneDesktopSync(store: store, health: health, companion: companion,
            sleepHealth: sleepHealth, player: player, content: content)
        #endif
        player.albumArtworkURLProvider = { [weak self] track in
            self?.content.albums.first(where: { $0.id == track.albumID })?.coverURL
        }
        #if os(iOS)
        if let snapshot = content.snapshot { downloads.reconcile(with: snapshot.tracks) }
        player.onlineURLProvider = { [weak self] track, allowCellular in
            guard let self else { throw URLError(.cancelled) }
            return try self.downloads.playbackURL(for: track, allowCellular: allowCellular)
        }
        player.didSelectOnline = { [weak self] track in self?.downloads.setPlayingTrack(track) }
        player.didStartOnline = { [weak self] track in
            self?.downloads.automaticallyCacheAfterPlaybackStarts(track)
            self?.content.recordPlayback(of: track)
        }
        content.didRefresh = { [weak self] snapshot in
            self?.player.reconcileOnlineCatalog(snapshot.tracks)
            self?.downloads.reconcile(with: snapshot.tracks)
            self?.desktopSync.catalogDataChanged()
        }
        content.didChangeService = { [weak self] in
            self?.player.reconcileOnlineCatalog([])
            self?.downloads.reconcile(with: [])
            if let self { self.link.publishContentServiceAddress(self.content.serviceAddress) }
        }
        link.publishContentServiceAddress(content.serviceAddress)
        #else
        if let snapshot = content.snapshot { downloads.reconcile(with: snapshot.tracks) }
        player.downloadedURLProvider = { [weak self] track in
            guard let self else { throw URLError(.cancelled) }
            return try self.downloads.playbackURL(for: track, allowCellular: false)
        }
        player.didSelectDownloaded = { [weak self] track in self?.downloads.setPlayingTrack(track) }
        content.didRefresh = { [weak self] snapshot in
            self?.player.reconcileDownloadedCatalog(snapshot.tracks)
            self?.downloads.reconcile(with: snapshot.tracks)
        }
        content.didChangeService = { [weak self] in
            self?.player.reconcileDownloadedCatalog([])
            self?.downloads.reconcile(with: [])
        }
        link.publicContentAddressReceived = { [weak self] address in
            do { try self?.content.setServiceAddress(address) }
            catch { self?.link.error = "内容服务地址未能同步，请在 iPhone 检查后重试。" }
        }
        #endif
        store.didChange = { [weak self] in self?.link.flush() }
        store.didChangeRecords = { [weak self] in
            self?.writeMoodSnapshot()
            #if os(iOS)
            self?.desktopSync.reportDataChanged()
            #endif
        }
        store.didChangePreferences = { [weak self] in self?.link.flush(); self?.writeSnapshot() }
        health.didRefresh = { [weak self] in
            guard let self else { return }
            self.writeSnapshot()
            if !self.health.isDemo { self.companion.captureHealthSummary(self.health.readings) }
            #if os(iOS)
            self.desktopSync.reportDataChanged()
            #endif
        }
        health.didUpdateForReminders = { [weak self] readings in
            guard let self else { return }
            #if os(iOS)
            await self.reminders.evaluate(readings: readings, isDemo: self.health.isDemo)
            #else
            await self.watchReminders.evaluate(readings: readings, healthConnected: self.health.requested, isDemo: self.health.isDemo)
            #endif
        }
        #if os(iOS)
        companion.didChangePractices = { [weak self] in self?.desktopSync.reportDataChanged() }
        sleepHealth.didRefresh = { [weak self] in self?.desktopSync.reportDataChanged() }
        reminders.didSubmit = { [weak self] id, date, sampleDate, title in
            do {
                try self?.companion.saveEvent(.init(id: id, date: date, title: title,
                    detail: "已提交系统，不能据此确认用户已收到。依据采样时间：\(sampleDate.formatted(date: .abbreviated, time: .shortened))。", kind: .reminder))
            } catch { self?.companion.error = "提醒提交记录暂未保存。" }
        }
        reminders.configurationDidChange = { [weak self] configuration in self?.link.publishReminderConfiguration(configuration) }
        link.reminderReadyReceived = { [weak self] ready in self?.reminders.acceptWatchMonitoring(ready) }
        link.reminderSignalReceived = { [weak self] signal in self?.reminders.receiveWatchSignal(signal) }
        link.watchReminderReportReceived = { [weak self] report in self?.reminders.receiveWatchReport(report) }
        link.reminderProbe = { [weak self] id in await self?.reminders.canDispatchWatchReminder(configurationID: id) ?? false }
        if !testing && !health.isDemo { link.publishReminderConfiguration(reminders.relayConfiguration) }
        #else
        watchReminders.didSubmit = { [weak self] id, date, sampleDate, title in
            do {
                try self?.companion.saveEvent(.init(id: id, date: date, title: title,
                    detail: "已提交手表系统，不代表已收到。依据采样时间：\(sampleDate.formatted(date: .abbreviated, time: .shortened))。", kind: .reminder))
            } catch { self?.companion.error = "提醒提交记录暂未保存。" }
        }
        watchReminders.requestOwnership = { [weak self] ready in self?.link.requestWatchMonitoring(ready) }
        watchReminders.probePhone = { [weak self] id in await self?.link.confirmPhoneForReminder(configurationID: id) ?? .unavailable }
        watchReminders.delegateToPhone = { [weak self] signal in self?.link.enqueueReminderSignal(signal) }
        watchReminders.publishReport = { [weak self] report in self?.link.publishWatchReminderReport(report) }
        link.reminderConfigurationReceived = { [weak self] configuration in
            guard let self else { return }
            if self.watchReminders.receive(configuration) {
                Task { await self.health.refreshReminderReadings() }
            }
        }
        #endif
        link.preferencesReceived = { [weak self] in self?.writeSnapshot() }
        // Activate at process launch so background transfers do not depend on a visible screen.
        if !testing {
            link.start()
            #if os(iOS)
            Task { [weak self] in await self?.desktopSync.start() }
            #endif
        }
        #if os(iOS)
        let publishPhoneState = player.didChangeState
        player.didChangeState = { [weak self] state in
            publishPhoneState?(state)
            self?.updateMusicWidget()
        }
        if WidgetAudioStorage.load() == nil { updateMusicWidget() }
        #endif
    }

    func start() async {
        await activate()
    }

    func activate() async {
        today = .now
        #if os(watchOS)
        refreshComplications()
        await watchReminders.activate(healthConnected: health.requested)
        #endif
        #if os(iOS)
        await sleepHealth.refresh()
        await reminders.refreshAuthorization()
        await reminders.resumePendingDispatches()
        if !needsHealthIntroduction && !healthIntroductionActive { await reminders.requestPermissionIfNeeded() }
        #endif
        player.reconcileDeadline()
        if !testing { link.flush() }
        await health.restoreBackgroundDelivery()
        await health.refresh()
        writeSnapshot(forceReload: true)
    }

    func updateClock() { today = .now; player.reconcileDeadline() }

    #if os(iOS)
    func updateMusicWidget() {
        guard !testing else { return }
        do {
            if try WidgetAudioStorage.save(WidgetAudioSnapshot(state: player.state)) {
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetAudioStorage.kind)
            }
            musicWidgetError = nil
        } catch { musicWidgetError = "音乐组件暂未更新，请重新打开小晴空后重试。" }
    }

    func playOnline(_ track: PublicAudioTrack, queue: [PublicAudioTrack], allowCellular: Bool) async {
        if player.isDesktopControlled {
            await player.selectOnline(track, queue: queue, url: track.audioURL, allowCellular: false)
            return
        }
        do {
            let url = try downloads.playbackURL(for: track, allowCellular: allowCellular)
            await player.selectOnline(track, queue: queue, url: url, allowCellular: allowCellular)
        } catch { player.reportPlaybackError(error.localizedDescription) }
    }
    #endif

    #if os(watchOS)
    func playDownloaded(_ track: PublicAudioTrack) async {
        let queue = content.tracks.filter { $0.albumID == track.albumID && downloads.localURL(for: $0) != nil }
        await player.selectDownloaded(track, queue: queue)
    }
    #endif

    #if os(watchOS)
    func refreshComplications() {
        guard !testing else { return }
        WidgetCenter.shared.invalidateConfigurationRecommendations()
        writeSnapshot(forceReload: true)
    }
    #endif

    private func writeMoodSnapshot() {
        guard !health.isDemo else { return }
        do {
            if try SnapshotStorage.saveMood(MoodSummary.latest(in: store.records), preferences: store.preferences) {
                WidgetCenter.shared.reloadTimelines(ofKind: "QingkongDumpling")
                #if os(iOS)
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetAudioStorage.kind)
                #endif
            }
            snapshotError = nil
        } catch { snapshotError = "心情组件暂未更新，请重新打开应用后重试。" }
    }

    private func writeSnapshot(forceReload: Bool = false) {
        guard !health.isDemo else { return }
        let latest = HealthMetric.allCases.compactMap { health.latest($0) }
        let trends = Dictionary(uniqueKeysWithValues: HealthMetric.allCases.map { metric in
            (metric, HealthMath.buckets(health.readings, metric: metric, period: .week))
        })
        do {
            let changed = try SnapshotStorage.save(ComplicationSnapshot(readings: latest, trends: trends, preferences: store.preferences, mood: MoodSummary.latest(in: store.records)))
            if changed || forceReload { WidgetCenter.shared.reloadAllTimelines() }
            snapshotError = nil
        } catch { snapshotError = "表盘数据暂未保存，请重新打开应用后重试。" }
    }
}
