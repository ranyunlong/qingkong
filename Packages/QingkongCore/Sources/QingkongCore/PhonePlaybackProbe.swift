/// Waits for a confirmed phone response before allowing local playback.
@MainActor
public enum PhonePlaybackProbe {
    public static func confirm(
        timeout: Duration = .seconds(8),
        retryInterval: Duration = .milliseconds(250),
        attempt: @MainActor (Duration) async -> Bool
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { return false }
            let confirmed = await attempt(remaining)
            try Task.checkCancellation()
            guard clock.now < deadline else { return false }
            if confirmed { return true }
            try await clock.sleep(until: min(deadline, clock.now.advanced(by: retryInterval)))
        }
    }
}
