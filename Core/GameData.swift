import Foundation

/// Persistent player state. UserDefaults is fine for a game this size;
/// migrate to a file/keychain if you later store anything sensitive.
final class GameData {
    static let shared = GameData()
    private let d = UserDefaults.standard

    private enum Key {
        static let coins = "gd.coins"
        static let maxUnlockedLevel = "gd.maxUnlockedLevel"
        static let adsRemoved = "gd.adsRemoved"
    }

    private init() {
        if d.object(forKey: Key.maxUnlockedLevel) == nil {
            d.set(0, forKey: Key.maxUnlockedLevel) // level index 0 unlocked by default
        }
    }

    var coins: Int {
        get { d.integer(forKey: Key.coins) }
        set { d.set(max(0, newValue), forKey: Key.coins) }
    }

    var maxUnlockedLevel: Int {
        get { d.integer(forKey: Key.maxUnlockedLevel) }
        set { d.set(max(maxUnlockedLevel, newValue), forKey: Key.maxUnlockedLevel) }
    }

    var adsRemoved: Bool {
        get { d.bool(forKey: Key.adsRemoved) }
        set { d.set(newValue, forKey: Key.adsRemoved) }
    }

    func addCoins(_ n: Int) { coins += n }
}
