/// `SpeakerRegistry`のprofileに保存された話者名を、そのcapture（timed.jsonl 1本）の中で
/// global idが初めて出た時に1回だけ`SpeakerNameRecord`として流すための判定。
/// `rename_speaker`（ユーザーの命名）と同じrecordを同じ経路で流すので、`Reconciler`と`render`は
/// 命名の出所を区別しなくてよい。名前の無いidは「未告知」のまま残し、後から名前が付いた時の初回に返す。
public struct ProfileNameAnnouncer: Sendable {
    private var announced: Set<String> = []

    public init() {}

    public mutating func record(for globalID: String, in registry: SpeakerRegistry) -> SpeakerNameRecord? {
        guard !announced.contains(globalID), let name = registry.name(for: globalID) else { return nil }
        announced.insert(globalID)
        return SpeakerNameRecord(speaker: globalID, name: name)
    }
}
