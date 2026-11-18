import Foundation

/// UserDefaults that live only in memory, for tests.
///
/// A real suite (`UserDefaults(suiteName:)`) leaves a plist in ~/Library/Preferences.
/// `removePersistentDomain(forName:)` empties it, but cfprefsd still writes an empty file
/// afterwards, even if the test deletes it. So tests use this instead: every typed getter and
/// setter (string, bool, data, stringArray, set(_:forKey:)) goes through these three
/// methods, and nothing is ever written to disk.
final class TestDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    convenience init() {
        // A nil suite reads nothing on its own; every read and write is overridden below.
        self.init(suiteName: nil)!
    }

    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
    override func removePersistentDomain(forName domainName: String) { values = [:] }
}
