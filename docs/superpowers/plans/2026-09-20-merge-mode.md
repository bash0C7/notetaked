# 後がけmergeモード Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 複数のMacで独立に収録した`timed.jsonl`を、後からiCloud Drive経由で持ち寄り自動的にmergeして1本の`final.md`/`timed.jsonl`にする（issue #4）。

**Architecture:** 各Macが収録停止時に`timed.jsonl`をiCloud Drive共有フォルダへコピーし、menubar appが定期的に`notetaked merge`を子processとして実行する。`merge`は時間範囲が重なるファイル同士を候補groupにまとめ、既存の`Reconciler`（merge mode専用の緩い時刻許容）で1本のutterance列に畳み込み、非破壊で新しい`<merged-prefix>.final.md`/`.timed.jsonl`を書く。manifestファイルで同じ組み合わせの二重mergeを防ぐ。

**Tech Stack:** Swift 6（strict concurrency）、swift-argument-parser、Swift Testing（`NotetakeCoreTests`）/ XCTest（`notetakedTests`、既存の`RawAudioReaderCaptureTests.swift`に倣う）、`FileManager.url(forUbiquityContainerIdentifier:)`（iCloud Drive）。

**Spec:** `docs/superpowers/specs/2026-09-20-merge-mode-design.md`

## Global Constraints

- v1のmerge対象は**複数Mac間のみ**。iPhone/Watchアプリへの変更は一切行わない（iPhone/Watchは現状standaloneで`timed.jsonl`を生成する経路を持たないため）
- 同期・merge対象は`timed.jsonl`のみ。生音声・`speakers.json`・`live.txt`は対象外
- merge mode専用の時刻許容窓は**`toleranceMS: 5_000`**（5秒）。現行のリアルタイム経路（peer接続、既定`Reconciler.Config()`の`toleranceMS: 1_000`）には一切触れない。textThresholdは既定0.5のまま変更しない
- 既存の統合ロジック（`Reconciler.apply(_:)`）・fold機構（`NDJSON.decodeAll`）・冪等性パターン（`~/Library/Application Support/Notetake/received/<device>.cursor`と同じディレクトリ規則）を再利用する
- 出力は非破壊。元の各Macの`timed.jsonl`/`final.md`は一切変更しない。新しい`<merged-prefix>.timed.jsonl`/`.final.md`を追加するのみ
- 起動経路は自動（menubar appの定期scan）+ 手動確認用CLI（`notetaked merge`）の両方
- iCloud Drive共有フォルダが使えない環境（iCloud未サインイン、entitlement未設定等）では、この機能はベストエフォートで無効化され、既存の収録・停止フローには一切影響しない

---

### Task 1: MergeCandidateGrouping（時刻重なりでの候補グループ化）

**Files:**
- Create: `Sources/NotetakeCore/Merge/MergeCandidateGrouping.swift`
- Test: `Tests/NotetakeCoreTests/MergeCandidateGroupingTests.swift`

**Interfaces:**
- Produces: `MergeCandidateGrouping.Source`（`id: String`, `records: [Record]`）、`MergeCandidateGrouping.timeRange(of: [Record]) -> (start: Int64, end: Int64)?`、`MergeCandidateGrouping.groups(from: [Source]) -> [[Source]]`。いずれも`public`（Task 6でnotetaked targetから呼ぶため）

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NotetakeCoreTests/MergeCandidateGroupingTests.swift
import Foundation
import Testing
@testable import NotetakeCore

private func seg(device: String, start: Int64, end: Int64, offset: Int64 = 0) -> Record {
    .segment(Segment(
        id: UUID(), session: "s1", seq: 0, device: device, deviceName: device,
        owner: "小芝", platform: .mac, source: .mic, input: .test,
        start: start, end: end, text: "こんにちは", clockOffsetMS: offset))
}

@Test func timeRangeSpansAllSegments() {
    let records: [Record] = [seg(device: "a", start: 0, end: 1000), seg(device: "a", start: 2000, end: 3000)]
    let range = MergeCandidateGrouping.timeRange(of: records)
    #expect(range?.start == 0)
    #expect(range?.end == 3000)
}

@Test func timeRangeAppliesClockOffset() {
    let records: [Record] = [seg(device: "a", start: 0, end: 1000, offset: 500)]
    let range = MergeCandidateGrouping.timeRange(of: records)
    #expect(range?.start == 500)
    #expect(range?.end == 1500)
}

@Test func timeRangeNilWhenNoSegments() {
    #expect(MergeCandidateGrouping.timeRange(of: []) == nil)
}

@Test func overlappingSourcesGroupTogether() {
    let a = MergeCandidateGrouping.Source(id: "a", records: [seg(device: "a", start: 0, end: 2000)])
    let b = MergeCandidateGrouping.Source(id: "b", records: [seg(device: "b", start: 1000, end: 3000)])
    let groups = MergeCandidateGrouping.groups(from: [a, b])
    #expect(groups.count == 1)
    #expect(Set(groups[0].map(\.id)) == ["a", "b"])
}

@Test func nonOverlappingSourcesStaySeparate() {
    let a = MergeCandidateGrouping.Source(id: "a", records: [seg(device: "a", start: 0, end: 1000)])
    let b = MergeCandidateGrouping.Source(id: "b", records: [seg(device: "b", start: 5000, end: 6000)])
    let groups = MergeCandidateGrouping.groups(from: [a, b])
    #expect(groups.count == 2)
}

@Test func transitiveOverlapJoinsThreeIntoOneGroup() {
    let a = MergeCandidateGrouping.Source(id: "a", records: [seg(device: "a", start: 0, end: 1500)])
    let b = MergeCandidateGrouping.Source(id: "b", records: [seg(device: "b", start: 1000, end: 2500)])
    let c = MergeCandidateGrouping.Source(id: "c", records: [seg(device: "c", start: 2000, end: 3500)])
    let groups = MergeCandidateGrouping.groups(from: [a, b, c])
    #expect(groups.count == 1)
    #expect(Set(groups[0].map(\.id)) == ["a", "b", "c"])
}

@Test func sourceWithNoSegmentsStaysAlone() {
    let a = MergeCandidateGrouping.Source(id: "a", records: [])
    let b = MergeCandidateGrouping.Source(id: "b", records: [seg(device: "b", start: 0, end: 1000)])
    let groups = MergeCandidateGrouping.groups(from: [a, b])
    #expect(groups.count == 2)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MergeCandidateGroupingTests`
Expected: FAIL（`MergeCandidateGrouping`が存在しない、コンパイルエラー）

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/NotetakeCore/Merge/MergeCandidateGrouping.swift
import Foundation

/// 複数source（Mac）が独立に持ち寄った`timed.jsonl`の内容から、時間範囲が重なる
/// もの同士をmerge候補groupとしてまとめる純粋関数群（issue #4 merge mode）。
public enum MergeCandidateGrouping {
    public struct Source: Sendable {
        public let id: String          // 例: "<device-id>_<prefix>"
        public let records: [Record]

        public init(id: String, records: [Record]) {
            self.id = id
            self.records = records
        }
    }

    /// `records`中の`.segment`から時間範囲（`start + clockOffsetMS`〜`end + clockOffsetMS`）を求める。
    /// `.segment`が1件も無ければnil
    public static func timeRange(of records: [Record]) -> (start: Int64, end: Int64)? {
        var minStart: Int64?
        var maxEnd: Int64?
        for record in records {
            guard case .segment(let seg) = record else { continue }
            let start = seg.start + seg.clockOffsetMS
            let end = seg.end + seg.clockOffsetMS
            minStart = min(minStart ?? start, start)
            maxEnd = max(maxEnd ?? end, end)
        }
        guard let minStart, let maxEnd else { return nil }
        return (minStart, maxEnd)
    }

    /// 時間範囲が少しでも重なっているsource同士を同一グループにまとめる（推移的に連結）。
    /// segが無い（時間範囲を持たない）sourceは常に単独グループになる。
    /// 呼び出し側は`group.count > 1`のものだけをmerge対象として扱うこと
    public static func groups(from sources: [Source]) -> [[Source]] {
        var remaining = sources
        var result: [[Source]] = []
        while !remaining.isEmpty {
            var group = [remaining.removeFirst()]
            var changed = true
            while changed {
                changed = false
                var i = 0
                while i < remaining.count {
                    if group.contains(where: { overlaps($0, remaining[i]) }) {
                        group.append(remaining.remove(at: i))
                        changed = true
                    } else {
                        i += 1
                    }
                }
            }
            result.append(group)
        }
        return result
    }

    private static func overlaps(_ a: Source, _ b: Source) -> Bool {
        guard let rangeA = timeRange(of: a.records), let rangeB = timeRange(of: b.records) else { return false }
        return rangeA.start <= rangeB.end && rangeB.start <= rangeA.end
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MergeCandidateGroupingTests`
Expected: PASS（7 tests）

- [ ] **Step 5: Commit**

```bash
git add Sources/NotetakeCore/Merge/MergeCandidateGrouping.swift Tests/NotetakeCoreTests/MergeCandidateGroupingTests.swift
git commit -m "feat(merge): add MergeCandidateGrouping for issue #4"
```

---

### Task 2: RecordStreamMerger（複数sourceのrecordを時刻順にインターリーブ）

**Files:**
- Create: `Sources/NotetakeCore/Merge/RecordStreamMerger.swift`
- Test: `Tests/NotetakeCoreTests/RecordStreamMergerTests.swift`

**Interfaces:**
- Consumes: `Record`（`Sources/NotetakeCore/Model/Record.swift`）
- Produces: `RecordStreamMerger.merge(_ streams: [[Record]]) -> [Record]`（`public`）

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NotetakeCoreTests/RecordStreamMergerTests.swift
import Foundation
import Testing
@testable import NotetakeCore

private func seg(device: String, start: Int64, end: Int64, text: String) -> Record {
    .segment(Segment(
        id: UUID(), session: "s1", seq: 0, device: device, deviceName: device,
        owner: "小芝", platform: .mac, source: .mic, input: .test,
        start: start, end: end, text: text))
}

private func rename(_ speaker: String, _ name: String) -> Record {
    .speakerName(SpeakerNameRecord(speaker: speaker, name: name))
}

@Test func interleavesTwoStreamsByTime() {
    let streamA: [Record] = [seg(device: "a", start: 0, end: 1000, text: "A1"), seg(device: "a", start: 4000, end: 5000, text: "A2")]
    let streamB: [Record] = [seg(device: "b", start: 2000, end: 3000, text: "B1")]
    let merged = RecordStreamMerger.merge([streamA, streamB])
    let texts = merged.compactMap { record -> String? in
        if case .segment(let seg) = record { return seg.text }
        return nil
    }
    #expect(texts == ["A1", "B1", "A2"])
}

@Test func preservesIntraStreamOrderWhenTimesTie() {
    let streamA: [Record] = [seg(device: "a", start: 1000, end: 2000, text: "A1")]
    let streamB: [Record] = [seg(device: "b", start: 1000, end: 2000, text: "B1")]
    let merged = RecordStreamMerger.merge([streamA, streamB])
    let texts = merged.compactMap { record -> String? in
        if case .segment(let seg) = record { return seg.text }
        return nil
    }
    #expect(texts == ["A1", "B1"])  // 同時刻ならstream順（streams配列の先頭が先）
}

@Test func nonSegmentRecordStaysBeforeItsFollowingSegment() {
    let streamA: [Record] = [
        rename("g1", "Kyoko"),
        seg(device: "a", start: 5000, end: 6000, text: "A1"),
    ]
    let streamB: [Record] = [seg(device: "b", start: 0, end: 1000, text: "B1")]
    let merged = RecordStreamMerger.merge([streamA, streamB])
    // rename("g1")はstream Aの次segment（A1）の直前にまとまって出る。B1はA1より早いので先に来る
    guard case .segment(let firstSeg) = merged[0] else { Issue.record("expected segment first"); return }
    #expect(firstSeg.text == "B1")
    guard case .speakerName(let renameRecord) = merged[1] else { Issue.record("expected speakerName second"); return }
    #expect(renameRecord.speaker == "g1")
    guard case .segment(let thirdSeg) = merged[2] else { Issue.record("expected segment third"); return }
    #expect(thirdSeg.text == "A1")
}

@Test func trailingNonSegmentRecordsAppendAtEnd() {
    let streamA: [Record] = [seg(device: "a", start: 0, end: 1000, text: "A1"), rename("g1", "Kyoko")]
    let merged = RecordStreamMerger.merge([streamA])
    #expect(merged.count == 2)
    guard case .speakerName = merged[1] else { Issue.record("expected trailing speakerName"); return }
}

@Test func emptyStreamsProduceEmptyResult() {
    #expect(RecordStreamMerger.merge([[], []]).isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RecordStreamMergerTests`
Expected: FAIL（`RecordStreamMerger`が存在しない）

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/NotetakeCore/Merge/RecordStreamMerger.swift
import Foundation

/// 複数source（各source内は元の順序のまま）のrecord列を、seg時刻
/// （`start + clockOffsetMS`）の昇順で1本にインターリーブする（issue #4 merge mode）。
/// `.session`/`.device`/`.speaker_name`など時刻を持たないrecordは、それに続く直後の
/// `.segment`の直前にまとめて出力される。最後の`.segment`より後に残った時刻を持たない
/// recordはstream順に末尾へ出力する。
public enum RecordStreamMerger {
    public static func merge(_ streams: [[Record]]) -> [Record] {
        var cursors = Array(repeating: 0, count: streams.count)
        var result: [Record] = []

        while true {
            var candidate: (stream: Int, segmentIndex: Int, time: Int64)?
            for streamIndex in streams.indices {
                var i = cursors[streamIndex]
                while i < streams[streamIndex].count {
                    if case .segment(let seg) = streams[streamIndex][i] {
                        let time = seg.start + seg.clockOffsetMS
                        if candidate == nil || time < candidate!.time {
                            candidate = (streamIndex, i, time)
                        }
                        break
                    }
                    i += 1
                }
            }
            guard let candidate else { break }
            for i in cursors[candidate.stream]...candidate.segmentIndex {
                result.append(streams[candidate.stream][i])
            }
            cursors[candidate.stream] = candidate.segmentIndex + 1
        }

        for streamIndex in streams.indices {
            while cursors[streamIndex] < streams[streamIndex].count {
                result.append(streams[streamIndex][cursors[streamIndex]])
                cursors[streamIndex] += 1
            }
        }
        return result
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter RecordStreamMergerTests`
Expected: PASS（5 tests）

- [ ] **Step 5: Commit**

```bash
git add Sources/NotetakeCore/Merge/RecordStreamMerger.swift Tests/NotetakeCoreTests/RecordStreamMergerTests.swift
git commit -m "feat(merge): add RecordStreamMerger for issue #4"
```

---

### Task 3: MergeEngine（候補groupを実際に統合する）

**Files:**
- Create: `Sources/NotetakeCore/Merge/MergeEngine.swift`
- Test: `Tests/NotetakeCoreTests/MergeEngineTests.swift`

**Interfaces:**
- Consumes: `MergeCandidateGrouping.Source`（Task 1）、`RecordStreamMerger.merge(_:)`（Task 2）、`Reconciler`/`Reconciler.Config`/`TranscriptRenderer.markdown(_:timeZone:)`（既存）
- Produces: `MergeEngine.mergeConfig: Reconciler.Config`（`public static let`）、`MergeEngine.MergeResult`（`sourceIDs: [String]`, `mergedRecords: [Record]`, `markdown: String`、いずれも`public let`）、`MergeEngine.merge(group: [MergeCandidateGrouping.Source]) -> MergeResult`（`public`）

- [ ] **Step 1: Write the failing test**

```swift
// Tests/NotetakeCoreTests/MergeEngineTests.swift
import Foundation
import Testing
@testable import NotetakeCore

private func seg(
    device: String, owner: String = "小芝", start: Int64, end: Int64, text: String,
    global: String? = nil
) -> Record {
    .segment(Segment(
        id: UUID(), session: "s1", seq: 0, device: device, deviceName: device,
        owner: owner, platform: .mac, source: .mic, input: .test,
        start: start, end: end, text: text,
        speaker: global.map { SpeakerTag(global: $0) }))
}

@Test func mergeConfigUsesFiveSecondTolerance() {
    #expect(MergeEngine.mergeConfig.toleranceMS == 5_000)
    #expect(MergeEngine.mergeConfig.textThreshold == 0.5)  // 既定のまま変更しない
}

@Test func mergeCombinesOverlappingCrossDeviceUtterances() {
    // 2台のMac、それぞれ別deviceで同じ発話を3.5秒ずれて記録（既定±1秒なら統合されないが、
    // merge modeの5秒許容とtext類似度で1件に統合される）
    let a = MergeCandidateGrouping.Source(
        id: "macA_2026-09-20_100000",
        records: [seg(device: "macA", start: 0, end: 2000, text: "今日はいい天気ですね")])
    let b = MergeCandidateGrouping.Source(
        id: "macB_2026-09-20_100000",
        records: [seg(device: "macB", start: 3500, end: 5500, text: "今日はいい天気ですね")])

    let result = MergeEngine.merge(group: [a, b])

    #expect(result.sourceIDs == ["macA_2026-09-20_100000", "macB_2026-09-20_100000"])
    #expect(result.mergedRecords.count == 2)  // 元の2 segはそのまま両方保持
    #expect(result.markdown.contains("今日はいい天気ですね"))
    #expect(result.markdown.split(separator: "\n").count == 1)  // Reconcilerが1 utteranceへ統合
}

@Test func mergeKeepsUnrelatedTextsSeparate() {
    let a = MergeCandidateGrouping.Source(
        id: "macA_p", records: [seg(device: "macA", start: 0, end: 1000, text: "おはようございます")])
    let b = MergeCandidateGrouping.Source(
        id: "macB_p", records: [seg(device: "macB", start: 500, end: 1500, text: "こんにちは")])

    let result = MergeEngine.merge(group: [a, b])
    #expect(result.markdown.split(separator: "\n").count == 2)  // text類似度が低く別utteranceのまま
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MergeEngineTests`
Expected: FAIL（`MergeEngine`が存在しない）

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/NotetakeCore/Merge/MergeEngine.swift
import Foundation

/// merge candidate group（Task 1で検出した2件以上のsource）を実際に統合し、
/// mergeされたrecord列と`final.md`相当のmarkdownを生成する（issue #4 merge mode）。
public enum MergeEngine {
    /// merge mode専用のReconciler.Config。現行のリアルタイム経路（peer接続、クロック補正済み、
    /// 既定`toleranceMS: 1_000`）とは別インスタンスで、既存の使用者向け挙動には一切影響しない。
    /// 後がけmergeはクロック補正の手段が無いため5秒まで許容する（user承認、2026-09-20）。
    /// Dice閾値（textThreshold）は既定のまま変更しない
    public static let mergeConfig: Reconciler.Config = {
        var config = Reconciler.Config()
        config.toleranceMS = 5_000
        return config
    }()

    public struct MergeResult: Sendable {
        public let sourceIDs: [String]      // groupに含まれるsource idそのまま（呼び出し側のmanifest key用）
        public let mergedRecords: [Record]  // 新しい<merged-prefix>.timed.jsonlの内容
        public let markdown: String         // 新しい<merged-prefix>.final.mdの内容

        public init(sourceIDs: [String], mergedRecords: [Record], markdown: String) {
            self.sourceIDs = sourceIDs
            self.mergedRecords = mergedRecords
            self.markdown = markdown
        }
    }

    /// 2件以上のsourceからなるgroupを統合する。呼び出し側で`group.count > 1`を保証すること
    public static func merge(group: [MergeCandidateGrouping.Source]) -> MergeResult {
        let merged = RecordStreamMerger.merge(group.map(\.records))

        var reconciler = Reconciler(config: mergeConfig)
        for record in merged {
            reconciler.apply(record)
        }
        let utterances = reconciler.resolveFallbackSpeakers()
        let markdown = TranscriptRenderer.markdown(utterances, timeZone: .current)

        return MergeResult(sourceIDs: group.map(\.id), mergedRecords: merged, markdown: markdown)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MergeEngineTests`
Expected: PASS（4 tests）

- [ ] **Step 5: Commit**

```bash
git add Sources/NotetakeCore/Merge/MergeEngine.swift Tests/NotetakeCoreTests/MergeEngineTests.swift
git commit -m "feat(merge): add MergeEngine for issue #4"
```

---

### Task 4: MergeManifest（merge済み組み合わせの冪等性）

**Files:**
- Create: `Sources/notetaked/Merge/MergeManifest.swift`
- Test: `Tests/notetakedTests/MergeManifestTests.swift`

**Interfaces:**
- Produces: `MergeManifest`（`init(url: URL)`）、`MergeManifest.default() -> MergeManifest`、`MergeManifest.key(forSourceIDs: [String]) -> String`（`static`）、`loadKeys() -> Set<String>`、`markMerged(_ key: String) throws`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/notetakedTests/MergeManifestTests.swift
import Foundation
import XCTest

@testable import notetaked

final class MergeManifestTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MergeManifestTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testLoadKeysReturnsEmptySetWhenFileMissing() {
        let manifest = MergeManifest(url: tempDir.appendingPathComponent("manifest.json"))
        XCTAssertEqual(manifest.loadKeys(), [])
    }

    func testMarkMergedPersistsKey() throws {
        let manifest = MergeManifest(url: tempDir.appendingPathComponent("manifest.json"))
        try manifest.markMerged("a,b")
        XCTAssertEqual(manifest.loadKeys(), ["a,b"])
    }

    func testMarkMergedAccumulatesMultipleKeys() throws {
        let manifest = MergeManifest(url: tempDir.appendingPathComponent("manifest.json"))
        try manifest.markMerged("a,b")
        try manifest.markMerged("c,d")
        XCTAssertEqual(manifest.loadKeys(), ["a,b", "c,d"])
    }

    func testKeyForSourceIDsIsOrderIndependent() {
        XCTAssertEqual(MergeManifest.key(forSourceIDs: ["b", "a"]), MergeManifest.key(forSourceIDs: ["a", "b"]))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MergeManifestTests`
Expected: FAIL（`MergeManifest`が存在しない）

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/notetaked/Merge/MergeManifest.swift
import Foundation

/// merge済みsourceの組み合わせを記録し、同じ組み合わせを再scanで二重にmergeしないための
/// 冪等性ファイル。`~/Library/Application Support/Notetake/merged/manifest.json`に、merge済み
/// key（sourceIDをsortしてカンマ結合したもの）の配列を保存する（`ReceivedCursor`と同じ
/// ディレクトリ規則・都度load/save方式、issue #4 merge mode）
struct MergeManifest {
    let url: URL

    static func `default`() -> MergeManifest {
        let supportDirectory =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return MergeManifest(
            url: supportDirectory.appendingPathComponent("Notetake/merged/manifest.json"))
    }

    /// sourceIDの組み合わせを識別するkey（順序に依存しないようsortしてカンマ結合）
    static func key(forSourceIDs sourceIDs: [String]) -> String {
        sourceIDs.sorted().joined(separator: ",")
    }

    /// ファイルが無い、または壊れていれば空集合
    func loadKeys() -> Set<String> {
        guard
            let data = try? Data(contentsOf: url),
            let keys = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(keys)
    }

    /// keyを追加してatomicに保存。ディレクトリが無ければ作成する
    func markMerged(_ key: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var keys = loadKeys()
        keys.insert(key)
        let data = try JSONEncoder().encode(keys.sorted())
        try data.write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MergeManifestTests`
Expected: PASS（4 tests）

- [ ] **Step 5: Commit**

```bash
git add Sources/notetaked/Merge/MergeManifest.swift Tests/notetakedTests/MergeManifestTests.swift
git commit -m "feat(merge): add MergeManifest idempotency store for issue #4"
```

---

### Task 5: ICloudMergeFolder（共有フォルダのURL解決 + ファイル名codec）

**Files:**
- Create: `Sources/notetaked/Merge/ICloudMergeFolder.swift`
- Test: `Tests/notetakedTests/ICloudMergeFolderTests.swift`

**Interfaces:**
- Produces: `ICloudMergeFolder.relativePath: String`、`ICloudMergeFolder.url() -> URL?`、`ICloudMergeFolder.exportedFilename(deviceID: String, prefix: String) -> String`、`ICloudMergeFolder.parseExportedFilename(_ filename: String) -> (deviceID: String, prefix: String)?`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/notetakedTests/ICloudMergeFolderTests.swift
import Foundation
import XCTest

@testable import notetaked

final class ICloudMergeFolderTests: XCTestCase {
    func testExportedFilenameFormat() {
        XCTAssertEqual(
            ICloudMergeFolder.exportedFilename(deviceID: "ABCD-1234", prefix: "2026-09-20_100000"),
            "ABCD-1234_2026-09-20_100000.timed.jsonl")
    }

    func testParseExportedFilenameRoundTrips() {
        let filename = ICloudMergeFolder.exportedFilename(deviceID: "ABCD-1234", prefix: "2026-09-20_100000")
        let parsed = ICloudMergeFolder.parseExportedFilename(filename)
        XCTAssertEqual(parsed?.deviceID, "ABCD-1234")
        XCTAssertEqual(parsed?.prefix, "2026-09-20_100000")
    }

    func testParseExportedFilenameHandlesUUIDDeviceID() {
        let filename = ICloudMergeFolder.exportedFilename(
            deviceID: "9B1DEB4D-3B7D-4BAD-9BDD-2B0D7B3DCB6D", prefix: "2026-09-20_235959")
        let parsed = ICloudMergeFolder.parseExportedFilename(filename)
        XCTAssertEqual(parsed?.deviceID, "9B1DEB4D-3B7D-4BAD-9BDD-2B0D7B3DCB6D")
        XCTAssertEqual(parsed?.prefix, "2026-09-20_235959")
    }

    func testParseExportedFilenameNilForWrongSuffix() {
        XCTAssertNil(ICloudMergeFolder.parseExportedFilename("device_2026-09-20_100000.final.md"))
    }

    func testParseExportedFilenameNilForTooShort() {
        XCTAssertNil(ICloudMergeFolder.parseExportedFilename("short.timed.jsonl"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ICloudMergeFolderTests`
Expected: FAIL（`ICloudMergeFolder`が存在しない）

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/notetaked/Merge/ICloudMergeFolder.swift
import Foundation

/// merge mode用のiCloud Drive共有フォルダ（ubiquity container配下）の場所を解決し、
/// エクスポートファイル名の生成・解析を行う（issue #4）。container identifierは
/// entitlement側で1つだけ登録する前提のため`nil`（既定container）を渡す。
/// iCloud未サインイン・entitlement未設定・iCloud Drive無効等では`url()`が`nil`を返し、
/// 呼び出し側はこの機能を使わずに続行する
enum ICloudMergeFolder {
    static let relativePath = "Documents/merge-sync"
    private static let prefixLength = 17  // "yyyy-MM-dd_HHmmss".count

    static func url() -> URL? {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            return nil
        }
        let folder = container.appendingPathComponent(relativePath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return folder
    }

    /// `<device-id>_<prefix>.timed.jsonl`
    static func exportedFilename(deviceID: String, prefix: String) -> String {
        "\(deviceID)_\(prefix).timed.jsonl"
    }

    /// `exportedFilename`の逆変換。prefixは固定長17文字（"yyyy-MM-dd_HHmmss"、
    /// `SessionStore.prefix(for:timeZone:)`のフォーマット）という前提で末尾から切り出す。
    /// 形式に合わなければnil
    static func parseExportedFilename(_ filename: String) -> (deviceID: String, prefix: String)? {
        guard filename.hasSuffix(".timed.jsonl") else { return nil }
        let stem = String(filename.dropLast(".timed.jsonl".count))
        guard stem.count > prefixLength + 1 else { return nil }
        let prefix = String(stem.suffix(prefixLength))
        let deviceID = String(stem.dropLast(prefixLength + 1))  // +1 は区切りの"_"
        return (deviceID, prefix)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ICloudMergeFolderTests`
Expected: PASS（5 tests。`url()`自体はiCloud entitlementが無いテスト環境では`nil`を返すのみで、このtaskではテスト対象にしない）

- [ ] **Step 5: Commit**

```bash
git add Sources/notetaked/Merge/ICloudMergeFolder.swift Tests/notetakedTests/ICloudMergeFolderTests.swift
git commit -m "feat(merge): add ICloudMergeFolder for issue #4"
```

---

### Task 6: `notetaked merge` CLIコマンド

**Files:**
- Create: `Sources/notetaked/Commands/MergeCommand.swift`
- Modify: `Sources/notetaked/Notetaked.swift`（`subcommands`に`Merge.self`を追加）
- Test: `Tests/notetakedTests/MergeCommandTests.swift`

**Interfaces:**
- Consumes: `MergeCandidateGrouping`（Task 1）、`MergeEngine`（Task 3）、`MergeManifest`（Task 4）、`ICloudMergeFolder`（Task 5）、`NDJSON.decodeAll(_:)`/`NDJSON.encode(_:)`（既存）
- Produces: `Merge.scan(directory: URL, manifest: MergeManifest) throws -> [String]`（`static`、テスト容易性のため`run()`から分離）、`Merge.mergedPrefix(for: [MergeCandidateGrouping.Source]) -> String`（`static`）

- [ ] **Step 1: Write the failing test**

```swift
// Tests/notetakedTests/MergeCommandTests.swift
import Foundation
import XCTest
import NotetakeCore

@testable import notetaked

final class MergeCommandTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MergeCommandTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func writeTimedFile(name: String, start: Int64, end: Int64, text: String) throws {
        // `.test` fixture（`Tests/NotetakeCoreTests/TestInputDevice.swift`）はNotetakeCoreTests
        // target専用でnotetakedTestsからは見えないため、本番コードにある`.system`を使う
        let record = Record.segment(Segment(
            id: UUID(), session: "s1", seq: 0, device: name, deviceName: name,
            owner: "小芝", platform: .mac, source: .mic, input: .system,
            start: start, end: end, text: text))
        let line = try NDJSON.encode(record) + "\n"
        try Data(line.utf8).write(to: tempDir.appendingPathComponent("\(name).timed.jsonl"))
    }

    func testScanMergesOverlappingFilesAndWritesOutput() throws {
        try writeTimedFile(name: "macA_2026-09-20_100000", start: 0, end: 2000, text: "こんにちは今日は")
        try writeTimedFile(name: "macB_2026-09-20_100003", start: 3500, end: 5500, text: "こんにちは今日は")

        let manifest = MergeManifest(url: tempDir.appendingPathComponent("manifest.json"))
        let logs = try Merge.scan(directory: tempDir, manifest: manifest)

        XCTAssertEqual(logs.count, 1)
        let mergedFinal = tempDir.appendingPathComponent("2026-09-20_100000_merged.final.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mergedFinal.path))
        let mergedTimed = tempDir.appendingPathComponent("2026-09-20_100000_merged.timed.jsonl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mergedTimed.path))
    }

    func testScanSkipsAlreadyMergedGroupOnRescan() throws {
        try writeTimedFile(name: "macA_2026-09-20_100000", start: 0, end: 2000, text: "こんにちは今日は")
        try writeTimedFile(name: "macB_2026-09-20_100003", start: 3500, end: 5500, text: "こんにちは今日は")

        let manifest = MergeManifest(url: tempDir.appendingPathComponent("manifest.json"))
        _ = try Merge.scan(directory: tempDir, manifest: manifest)
        let secondRunLogs = try Merge.scan(directory: tempDir, manifest: manifest)

        XCTAssertEqual(secondRunLogs.count, 0)
    }

    func testScanIgnoresNonOverlappingFiles() throws {
        try writeTimedFile(name: "macA_2026-09-20_100000", start: 0, end: 1000, text: "おはよう")
        try writeTimedFile(name: "macB_2026-09-20_200000", start: 36000000, end: 36001000, text: "こんばんは")

        let manifest = MergeManifest(url: tempDir.appendingPathComponent("manifest.json"))
        let logs = try Merge.scan(directory: tempDir, manifest: manifest)
        XCTAssertEqual(logs.count, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MergeCommandTests`
Expected: FAIL（`Merge`が存在しない）

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/notetaked/Commands/MergeCommand.swift
import ArgumentParser
import Foundation
import NotetakeCore

struct Merge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge",
        abstract: "Scan a directory (default: the iCloud Drive merge-sync folder) for "
            + "independently-recorded <device-id>_<prefix>.timed.jsonl files and merge overlapping ones"
    )

    @Option(help: "Directory to scan. Defaults to ICloudMergeFolder.url() (iCloud Drive merge-sync folder)")
    var scan: String?

    func run() async throws {
        guard let directory = scan.map({ URL(fileURLWithPath: $0) }) ?? ICloudMergeFolder.url() else {
            print("merge: no iCloud merge folder available, skipping")
            return
        }
        let logs = try Merge.scan(directory: directory, manifest: MergeManifest.default())
        for line in logs { print(line) }
    }

    /// 実際のscan+merge処理。`run()`から分離しテスト容易にする
    static func scan(directory: URL, manifest: MergeManifest) throws -> [String] {
        let filenames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".timed.jsonl") }
            .sorted()

        var sources: [MergeCandidateGrouping.Source] = []
        for filename in filenames {
            let fileURL = directory.appendingPathComponent(filename)
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            let sourceID = String(filename.dropLast(".timed.jsonl".count))
            sources.append(MergeCandidateGrouping.Source(id: sourceID, records: NDJSON.decodeAll(text)))
        }

        let alreadyMerged = manifest.loadKeys()
        var logs: [String] = []

        for group in MergeCandidateGrouping.groups(from: sources) where group.count > 1 {
            let key = MergeManifest.key(forSourceIDs: group.map(\.id))
            guard !alreadyMerged.contains(key) else { continue }

            let result = MergeEngine.merge(group: group)
            let prefix = Merge.mergedPrefix(for: group)
            let timedLines = try result.mergedRecords.map { try NDJSON.encode($0) }
            let timedText = timedLines.joined(separator: "\n") + "\n"
            try Data(timedText.utf8).write(
                to: directory.appendingPathComponent("\(prefix).timed.jsonl"), options: .atomic)
            try Data(result.markdown.utf8).write(
                to: directory.appendingPathComponent("\(prefix).final.md"), options: .atomic)
            try manifest.markMerged(key)
            logs.append("merged \(group.map(\.id).joined(separator: ", ")) -> \(prefix)")
        }
        return logs
    }

    /// group内で最も開始時刻が早いsourceの元prefixに"_merged"を付けたものをmerged prefixとする。
    /// 元prefixが取り出せない（想定外のファイル名形式の）場合はsource idを結合したものへfallback
    static func mergedPrefix(for group: [MergeCandidateGrouping.Source]) -> String {
        let earliest = group.min { a, b in
            let startA = MergeCandidateGrouping.timeRange(of: a.records)?.start ?? .max
            let startB = MergeCandidateGrouping.timeRange(of: b.records)?.start ?? .max
            return startA < startB
        }
        guard
            let earliest,
            let parsed = ICloudMergeFolder.parseExportedFilename("\(earliest.id).timed.jsonl")
        else {
            return "merged_\(group.map(\.id).sorted().joined(separator: "_"))"
        }
        return "\(parsed.prefix)_merged"
    }
}
```

- [ ] **Step 4: Wire into the subcommand list**

`Sources/notetaked/Notetaked.swift`を編集:

```swift
import ArgumentParser

@main
struct Notetaked: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "notetaked",
        abstract: "Notetake transcription daemon",
        version: "0.1.0",
        subcommands: [Serve.self, Render.self, Transcribe.self, Capture.self, CaptureDaemon.self, Polish.self, Merge.self]
    )

    func run() async throws {
        throw CleanExit.helpRequest(self)
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter MergeCommandTests`
Expected: PASS（3 tests）

- [ ] **Step 6: Commit**

```bash
git add Sources/notetaked/Commands/MergeCommand.swift Sources/notetaked/Notetaked.swift Tests/notetakedTests/MergeCommandTests.swift
git commit -m "feat(merge): add notetaked merge CLI command for issue #4"
```

---

### Task 7: Mac appの署名切り替え + iCloud container entitlement追加（インフラ、**user立会い必須**）

**Files:**
- Modify: `Apps/project.yml`（`Notetake`targetの`settings.base`から`CODE_SIGN_STYLE: Manual`/`CODE_SIGN_IDENTITY: "-"`を削除し、`entitlements`ブロックを追加）
- Modify: `Makefile`（`DAEMON_IDENTITY`の既定値をHANDOFF記載の有効identityへ）

**このtaskの前提・リスク（実装前に必ず読むこと）**:
- Mac app（`Notetake`target）は現在ad-hoc署名（`CODE_SIGN_IDENTITY: "-"`）。ad-hoc署名にはprovisioning profileが無く、iCloud container等のApple管理entitlementは一切使えない。iCloud Drive共有フォルダ（Task 5の`ICloudMergeFolder.url()`）を実際に機能させるには、Apple Development identityでの署名へ切り替える必要がある
- 有効なidentity（`A3F23595F28DC4E18B5063DF519E424A44778AB4`、`HANDOFF.md`記載、2026-09-13再発行）が既にkeychainにある
- 署名を切り替えるとTCC（マイク／システム音声）の再許可ダイアログが出る可能性がある。**userが画面の前にいる時に実行すること**（既存の`HANDOFF.md`「申し送り」節と同じ制約）
- **未確認のリスク**: Apple Developer Team（`SM5792D355`）がFree/Personal Teamの場合、iCloud capability自体が使えない（Apple側の制約、Automatic signingでは回避不可）。このtaskの実行前に、Xcode（Signing & Capabilities）または`xcrun devicectl`等でこのTeamがiCloud capabilityを追加できるか確認すること。**使えないと判明した場合はこのtask・Task 8・Task 9を実装せず、Task 1〜6（CLIで明示的にディレクトリを指定するmerge処理）のみをこのplanの成果として確定し、HANDOFFに制約として記録すること**（Task 1〜6はiCloud非依存で完結しており無駄にならない）

- [ ] **Step 1: project.ymlを編集**

`Apps/project.yml`の`Notetake`targetから以下の2行を削除:

```yaml
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: "-"
```

同じtargetに`entitlements`ブロックを追加（`type: application`の直後、`sources:`の前でも後でも良い。既存の`info:`ブロックと同じ階層）:

```yaml
    entitlements:
      path: Notetake/Notetake.entitlements
      properties:
        com.apple.developer.icloud-container-identifiers:
          - iCloud.io.github.bash0c7.notetake
        com.apple.developer.icloud-services:
          - CloudDocuments
```

- [ ] **Step 2: Makefileを編集**

`Makefile`の`DAEMON_IDENTITY ?= -`を、HANDOFFに記載の有効identityへ変更:

```makefile
DAEMON_IDENTITY ?= A3F23595F28DC4E18B5063DF519E424A44778AB4
```

- [ ] **Step 3: プロジェクトを再生成しビルド確認**

```bash
make project
make app
```

Expected: ビルド成功。失敗する場合、Xcodeで`Apps/Notetake.xcodeproj`を開き「Signing & Capabilities」タブでiCloud capabilityのエラー文言を確認する（Team不足・container未登録等）

- [ ] **Step 4: userの立会いで起動確認**

`make app`後、`.build/DerivedData/Build/Products/Debug/Notetake.app`をuserの目の前で起動し、TCC再許可ダイアログが出たら承認してもらう。マイク・システム音声の収録が引き続き動くことを確認

- [ ] **Step 5: Commit**

```bash
git add Apps/project.yml Makefile
git commit -m "feat(merge): sign Mac app with Apple Development identity, add iCloud entitlement for issue #4"
```

---

### Task 8: `ServeSession.stopCapture()`からのiCloudエクスポート配線

**Files:**
- Modify: `Sources/notetaked/Pipeline/ServeSession.swift:508-557`（`stopCapture()`、`await store.close()`の直後）

**Interfaces:**
- Consumes: `ICloudMergeFolder.url()`/`ICloudMergeFolder.exportedFilename(deviceID:prefix:)`（Task 5）、`ServeSession`の既存`private let device: DeviceIdentity`（`Sources/notetaked/Pipeline/ServeSession.swift:56`）、`SessionStore`の`nonisolated let prefix: String` / `nonisolated let timedURL: URL`（既存）

- [ ] **Step 1: `stopCapture()`に配線するprivateメソッドを追加**

`Sources/notetaked/Pipeline/ServeSession.swift`の`stopCapture()`メソッド（508行目付近）の直前に追加:

```swift
    /// merge mode用: 停止したセッションのtimed.jsonlをiCloud Drive共有フォルダへコピーする
    /// （issue #4）。iCloudが使えない環境ではベストエフォートで諦め、停止処理自体は継続する
    private func exportToMergeFolder(prefix: String, timedURL: URL) async {
        guard let folder = ICloudMergeFolder.url() else { return }
        let filename = ICloudMergeFolder.exportedFilename(deviceID: device.id, prefix: prefix)
        let destination = folder.appendingPathComponent(filename)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: timedURL, to: destination)
        } catch {
            await control.send(.log("merge export skipped: \(error)"))
        }
    }
```

- [ ] **Step 2: `stopCapture()`本体から呼ぶ**

`Sources/notetaked/Pipeline/ServeSession.swift:547`付近、`await store.close()`の直後（`self.store = nil`の前）に1行追加:

```swift
        await store.close()

        await exportToMergeFolder(prefix: store.prefix, timedURL: store.timedURL)

        self.store = nil
```

- [ ] **Step 3: ビルド確認**

```bash
swift build 2>&1 | grep -i warning
```

Expected: 出力なし（警告ゼロ）。このtaskは既存の`RawAudioReaderCaptureTests.swift`のようなfixture外部化が難しい（`ServeSession`全体をテスト用に起動する必要があり、既存テストにもServeSession単体の統合テストは無い）ため、新規unit testは追加しない。代わりにTask 5で`ICloudMergeFolder`の純粋なファイル名生成・解析部分は既にテスト済み。実際の動作確認はTask 7完了後、Mac実機で2つの独立収録を行いiCloud Driveへコピーされることを目視確認する（次のCLIセッションへ持ち越し可）

- [ ] **Step 4: Commit**

```bash
git add Sources/notetaked/Pipeline/ServeSession.swift
git commit -m "feat(merge): export timed.jsonl to iCloud on stop for issue #4"
```

---

### Task 9: Menubar appの自動merge scanループ

**Files:**
- Modify: `Apps/Notetake/AppModel.swift`（末尾に新規セクション追加）
- Modify: `Apps/Notetake/NotetakeApp.swift:8`（`applicationDidFinishLaunching`）

**Interfaces:**
- Consumes: `AppModel`の既存`Bundle.main.executableURL`解決パターン（`polishLastRecording()`、`Sources/notetaked/... `の`notetaked`実行ファイル埋め込み）、`Process`/`Pipe`（既存`polishLastRecording()`と同じパターン）

- [ ] **Step 1: AppModelにscanループを追加**

`Apps/Notetake/AppModel.swift`の末尾（既存の`// MARK: - Auto rotation`セクションの後）に追加:

```swift
    // MARK: - Merge scan (issue #4)

    private var mergeScanTask: Task<Void, Never>?
    var isMergeScanning = false

    /// menubar app起動時に呼ぶ。iCloud merge共有フォルダを10分間隔でscanし、
    /// `notetaked merge`を子processとして実行する。iCloud未設定の環境では
    /// notetaked側の`ICloudMergeFolder.url()`が`nil`を返しすぐ終了するだけで実害は無い
    func startMergeScanLoop() {
        mergeScanTask?.cancel()
        mergeScanTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.runMergeScan()
                try? await Task.sleep(until: .now + .seconds(600), clock: .continuous)
            }
        }
    }

    private func runMergeScan() {
        guard !isMergeScanning else { return }
        guard let executable = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("notetaked")
        else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["merge"]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        process.terminationHandler = { [weak self] finishedProcess in
            let stdoutData = stdoutHandle.readDataToEndOfFile()
            let stderrData = stderrHandle.readDataToEndOfFile()
            Task { @MainActor in
                guard let self else { return }
                self.isMergeScanning = false
                guard finishedProcess.terminationStatus == 0 else {
                    let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
                    let lastLine = stderrText
                        .split(separator: "\n", omittingEmptySubsequences: true)
                        .last.map(String.init) ?? ""
                    self.lastError = "merge scanに失敗しました (code \(finishedProcess.terminationStatus)): \(lastLine)"
                    return
                }
                let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
                let mergedLines = stdoutText
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .filter { $0.hasPrefix("merged ") }
                if let lastMerge = mergedLines.last {
                    self.lastLog = String(lastMerge)
                }
            }
        }
        do {
            try process.run()
            isMergeScanning = true
        } catch {
            lastError = "merge scanの起動に失敗しました: \(error.localizedDescription)"
        }
    }
```

- [ ] **Step 2: 起動時に呼ぶ**

`Apps/Notetake/NotetakeApp.swift:8`を編集:

```swift
    func applicationDidFinishLaunching(_ notification: Notification) {
        appModel.ensureDaemon()
        appModel.startMergeScanLoop()
    }
```

- [ ] **Step 3: ビルド確認**

```bash
make app
```

Expected: ビルド成功。このtaskはUI/subprocess起動が主体でXCTest/Swift Testingでの自動テストは書かない（既存の`polishLastRecording()`/`scheduleRotation()`も同様に無テスト）。動作確認はTask 7完了・実機でのiCloud設定完了後、2台のMac（または1台+別Apple IDでの検証環境）で実施する

- [ ] **Step 4: Commit**

```bash
git add Apps/Notetake/AppModel.swift Apps/Notetake/NotetakeApp.swift
git commit -m "feat(merge): run automatic merge scan loop in menubar app for issue #4"
```

---

## 実機検証（このplanの範囲外、次回Mac実機セッションで実施）

- Task 7完了後、2台のMac（または1台のMacと2つの独立した収録ディレクトリ）でそれぞれ収録→停止し、iCloud Drive共有フォルダへ`timed.jsonl`がコピーされることを確認
- 時間の重なる2つの収録を用意し、`notetaked merge`（またはmenubar appの自動scan）が`<prefix>_merged.final.md`を生成し、両Macの発話が1本のtranscriptに統合されることを確認
- 重ならない収録が誤ってmergeされないこと、既にmerge済みの組み合わせが再scanで二重にmergeされないこと（`manifest.json`の内容も確認）
- このplanと合わせて、issue #18（実機検証済み）・#8（実会話確認）・#2（4方向計測）もまとめて実施し、draft PR #19（またはこのplanの新規branch）をmerge判断できる状態にする
