import Foundation
import QingkongCore

private enum CheckFailure: Error { case failed(String) }

@main
struct CompanionMilestoneChecks {
    @MainActor static func main() throws {
        let root = URL.temporaryDirectory.appending(path: "qingkong-milestone-check-" + UUID().uuidString)
        let suite = "qingkong.milestone-check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        let moodKey = "companion.actions.nodUnlocked"
        let practiceKey = "companion.actions.swayUnlocked"
        let store = try LocalStore(directoryOverride: root.appending(path: "moods"), defaultsOverride: defaults)
        try check(!defaults.bool(forKey: moodKey) && !defaults.bool(forKey: practiceKey), "empty stores must not unlock milestones")
        try store.add(mood: 1, stress: 5, note: "Private text", tags: [.work])
        try check(defaults.bool(forKey: moodKey), "saving a mood must remember the nod without opening any view")
        try store.delete(store.entries[0])
        let restarted = try LocalStore(directoryOverride: root.appending(path: "moods"), defaultsOverride: defaults)
        try check(restarted.entries.isEmpty && defaults.bool(forKey: moodKey), "deletion and relaunch must retain the nod")
        print("PASS: mood save unlocks immediately and deletion/relaunch retain it without any UI")

        let companionURL = root.appending(path: "companion.json")
        let companion = try CompanionStore(url: companionURL, defaultsOverride: defaults)
        let end = Date.now.addingTimeInterval(-1)
        let practice = RelaxationRecord(duration: .oneMinute, mode: .quiet, startedAt: end.addingTimeInterval(-60), completedAt: end)
        try companion.savePractice(practice)
        try check(defaults.bool(forKey: practiceKey), "saving a completed practice must remember the sway without opening any view")
        try companion.deletePractice(practice.id)
        try check(try CompanionStore(url: companionURL, defaultsOverride: defaults).practices.isEmpty && defaults.bool(forKey: practiceKey), "deletion and relaunch must retain the sway")
        print("PASS: completed practice unlocks immediately and deletion/relaunch retain it without any UI")

        defaults.removeObject(forKey: moodKey)
        defaults.removeObject(forKey: practiceKey)
        try store.save(MoodRecord(mood: 4, stress: 2, note: "Existing record"))
        defaults.removeObject(forKey: moodKey)
        _ = try LocalStore(directoryOverride: root.appending(path: "moods"), defaultsOverride: defaults)
        try check(defaults.bool(forKey: moodKey), "existing local moods must migrate on store load")
        try companion.savePractice(practice)
        defaults.removeObject(forKey: practiceKey)
        _ = try CompanionStore(url: companionURL, defaultsOverride: defaults)
        try check(defaults.bool(forKey: practiceKey), "existing practices must migrate on store load")
        print("PASS: existing records migrate milestones when stores load")

        let flags = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("companion.actions.") }
        try check(Set(flags.keys) == [moodKey, practiceKey] && flags.values.allSatisfy { $0 is Bool }, "milestones store only two booleans")
        print("PASS: milestone memory contains only the two unlock flags")
        print("4 native milestone checks passed; no views, network, simulator, or device used.")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure.failed(message) }
    }
}
