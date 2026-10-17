/// pin状態を踏まえた入力デバイス解決（純粋関数）。オーディオハードウェア無しでテストできる
public enum InputDeviceResolution {
    /// pinされたUIDが指定されており、かつ接続中デバイス一覧に含まれていればそのUIDを返す。
    /// それ以外（pin無し、またはpin先が接続中で無い）はnil（= OS既定入力を使う）を返す
    public static func resolvedUID(pinnedUID: String?, availableUIDs: Set<String>) -> String? {
        guard let pinnedUID, availableUIDs.contains(pinnedUID) else { return nil }
        return pinnedUID
    }

    /// 内蔵マイクのUID
    public static let builtInUID = "BuiltInMicrophoneDevice"

    /// 取り込み先を決められなかった時の行き先。OS既定が候補にあってContinuityなら捨てる。
    /// OS既定が候補に無ければ種別が分からないのでそのまま返す。使えなければ候補の先頭の内蔵、無ければnil
    public static func fallbackUID(osDefaultUID: String?, candidates: [InputCandidate]) -> String? {
        if let osDefaultUID {
            let known = candidates.first { $0.uid == osDefaultUID }
            if known?.transport != .continuity { return osDefaultUID }
        }
        return candidates.first { $0.transport == .builtIn }?.uid
    }

    /// 保存された選択のUIDを整える。候補にあってContinuityの時だけnil、それ以外（切断中の機器を含む）はそのまま返す
    public static func sanitizedPreferredUID(_ uid: String?, candidates: [InputCandidate]) -> String? {
        guard let uid else { return nil }
        let known = candidates.first { $0.uid == uid }
        return known?.transport == .continuity ? nil : uid
    }
}
