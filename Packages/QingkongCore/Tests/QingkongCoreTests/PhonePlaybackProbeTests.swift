import Testing
@testable import QingkongCore

@MainActor
struct PhonePlaybackProbeTests {
    @Test func waitsForPhoneInsteadOfFallingBackOnFirstUnavailableCheck() async throws {
        var attempts = 0
        let confirmed = try await PhonePlaybackProbe.confirm(timeout: .seconds(2), retryInterval: .milliseconds(1)) { _ in
            attempts += 1
            return attempts == 3
        }
        #expect(confirmed)
        #expect(attempts == 3)
    }

    @Test func confirmedPhoneDoesNotWaitForTimeout() async throws {
        var attempts = 0
        let confirmed = try await PhonePlaybackProbe.confirm { _ in
            attempts += 1
            return true
        }
        #expect(confirmed)
        #expect(attempts == 1)
    }

    @Test func unavailablePhoneFallsBackOnlyAfterDeadline() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        var attempts = 0
        let confirmed = try await PhonePlaybackProbe.confirm(timeout: .milliseconds(30), retryInterval: .milliseconds(5)) { remaining in
            #expect(remaining > .zero)
            #expect(remaining <= .milliseconds(30))
            attempts += 1
            return false
        }
        #expect(!confirmed)
        #expect(start.duration(to: clock.now) >= .milliseconds(30))
        #expect(attempts >= 1)
    }

    @Test func replyAfterDeadlineDoesNotConfirmPhone() async throws {
        let confirmed = try await PhonePlaybackProbe.confirm(timeout: .milliseconds(10)) { _ in
            try? await Task.sleep(for: .milliseconds(20))
            return true
        }
        #expect(!confirmed)
    }

    @Test func cancellingWaitDoesNotAuthorizeLocalFallback() async {
        var attempts = 0
        let task = Task {
            try await PhonePlaybackProbe.confirm { _ in
                attempts += 1
                return false
            }
        }
        while attempts == 0 { await Task.yield() }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("取消等待应终止操作，不能当成手机离线后开播")
        } catch is CancellationError {
        } catch {
            Issue.record("意外错误：\(error)")
        }
    }
}
