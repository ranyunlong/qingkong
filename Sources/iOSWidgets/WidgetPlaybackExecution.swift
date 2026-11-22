import AppIntents
import Foundation

extension MusicPlaybackIntent {
    func perform() async throws -> some IntentResult {
        // Playback must run in the containing app, never in a second extension player.
        try requireContainingApp()
        return .result()
    }

    private func requireContainingApp() throws {
        throw NSError(domain: "Qingkong.WidgetPlayback", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "请打开小晴空后重试播放。"])
    }
}
