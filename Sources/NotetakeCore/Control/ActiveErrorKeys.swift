import Foundation

/// いまエラー中のkeyの集まり。回復を毎回送らず、エラー中だった時だけ送るために使う
public struct ActiveErrorKeys: Sendable {
    private var keys: Set<String> = []

    public init() {}

    public mutating func fail(_ key: String) {
        keys.insert(key)
    }

    /// エラー中だったkeyだけtrue（呼び出し側はtrueの時だけ`resolved`を送る）
    public mutating func resolve(_ key: String) -> Bool {
        keys.remove(key) != nil
    }
}
