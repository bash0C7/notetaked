import Foundation

/// `<prefix>.speakers.json`。最新の回の話者と、名前を引き継ぐための声の特徴（centroid）を持つ。
/// 従来の形式は大域の話者profileの配列で、回の番号を持たない。`read`はそれを確定済みとして扱わず、nilを返す
public struct SpeakersFile: Codable, Equatable, Sendable {
    public struct Speaker: Codable, Equatable, Sendable {
        public var id: String
        public var source: Source
        public var name: String?
        public var speechSeconds: Double
        public var excerpt: String
        public var firstStartMS: Int64
        public var centroid: [Float]

        enum CodingKeys: String, CodingKey {
            case id
            case source
            case name
            case speechSeconds = "speech_seconds"
            case excerpt
            case firstStartMS = "first_start_ms"
            case centroid
        }

        public init(
            id: String, source: Source, name: String? = nil, speechSeconds: Double, excerpt: String,
            firstStartMS: Int64, centroid: [Float]
        ) {
            self.id = id
            self.source = source
            self.name = name
            self.speechSeconds = speechSeconds
            self.excerpt = excerpt
            self.firstStartMS = firstStartMS
            self.centroid = centroid
        }

        /// 名前が無ければ「話者1」等
        public var displayName: String { name ?? SpeakerLabel.defaultName(for: id) }
    }

    public var run: Int
    public var speakers: [Speaker]

    public init(run: Int, speakers: [Speaker]) {
        self.run = run
        self.speakers = speakers
    }

    public static func url(prefix: String, directory: URL) -> URL {
        directory.appendingPathComponent("\(prefix).speakers.json")
    }

    /// ファイルが無い、または従来の形式（JSONの配列）ならnil。新しい形式で壊れていればthrowする
    public static func read(from url: URL) throws -> SpeakersFile? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        if data.first(where: { !" \n\r\t".utf8.contains($0) }) == UInt8(ascii: "[") {
            return nil
        }
        return try JSONDecoder().decode(SpeakersFile.self, from: data)
    }

    public func write(to url: URL) throws {
        try JSONFile.write(self, to: url)
    }

    /// 空の名前は取り消しで、`name`がnilに戻る。`id`の話者が無ければnil
    public func renaming(id: String, to name: String) -> SpeakersFile? {
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = self
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.speakers[index].name = trimmed.isEmpty ? nil : trimmed
        return copy
    }

    /// `from`を`into`へまとめる。声の特徴は発話秒数で重み付けして平均し、発話秒数は足し、
    /// 最初の発話の抜粋は早い方を使う。名前は`into`を優先し、無ければ`from`のものを使う。
    /// どちらかが無い、または同じ話者ならnil
    public func merging(from: String, into: String) -> SpeakersFile? {
        guard from != into,
            let fromIndex = speakers.firstIndex(where: { $0.id == from }),
            let intoIndex = speakers.firstIndex(where: { $0.id == into })
        else { return nil }
        let source = speakers[fromIndex]
        var target = speakers[intoIndex]
        let total = source.speechSeconds + target.speechSeconds
        let sourceWeight = total > 0 ? source.speechSeconds / total : 0.5
        let targetWeight = 1 - sourceWeight
        if source.centroid.count == target.centroid.count {
            target.centroid = zip(source.centroid, target.centroid).map {
                Float(sourceWeight) * $0 + Float(targetWeight) * $1
            }
        }
        target.speechSeconds = total
        target.name = target.name ?? source.name
        if source.firstStartMS < target.firstStartMS {
            target.firstStartMS = source.firstStartMS
            target.excerpt = source.excerpt
        }
        var copy = self
        copy.speakers[intoIndex] = target
        copy.speakers.remove(at: fromIndex)
        return copy
    }

    /// `records`にある、この回の名前とまとめを順に当てる。既に当てた記録を当て直しても結果は変わらない。
    /// 取り込みの途中で落ちた後に、`timed.jsonl`と食い違う`speakers.json`を直すために使う
    public func reconciled(with records: [Record]) -> SpeakersFile {
        var file = self
        for record in records {
            switch record {
            case .speakerName(let rename) where rename.run == run:
                file = file.renaming(id: rename.speaker, to: rename.name) ?? file
            case .speakerMerge(let merge) where merge.run == run:
                file = file.merging(from: merge.from, into: merge.into) ?? file
            default:
                break
            }
        }
        return file
    }
}
