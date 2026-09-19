/// pin状態を踏まえた入力デバイス解決（純粋関数）。オーディオハードウェア無しでテストできる
public enum InputDeviceResolution {
    /// pinされたUIDが指定されており、かつ接続中デバイス一覧に含まれていればそのUIDを返す。
    /// それ以外（pin無し、またはpin先が接続中で無い）はnil（= OS既定入力を使う）を返す
    public static func resolvedUID(pinnedUID: String?, availableUIDs: Set<String>) -> String? {
        guard let pinnedUID, availableUIDs.contains(pinnedUID) else { return nil }
        return pinnedUID
    }
}
