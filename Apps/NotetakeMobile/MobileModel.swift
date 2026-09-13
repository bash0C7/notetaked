import Foundation
import NotetakeCore
import WatchConnectivity

/// `self`（`@MainActor`だがSendable宣言はしていないクラス）を、actor（`PeerClient`/`Recorder`）から
/// 呼ばれる`@Sendable`closureの中で弱参照するための薄いbox。
/// `value`への実際のアクセスは常に`Task { @MainActor in }`の中で行うため`@unchecked`は安全
/// （`AudioConverter`が同じ考え方で`@unchecked Sendable`にしているのに倣う）。
private final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

/// iPhone appの中心的な状態: 設定・outbox・PeerClient・Recorderをまとめ、UIへ状態を出す
@MainActor
@Observable
final class MobileModel {
    // ContentViewが`$model.settings.ownerName`のようにBindingを辿れるよう`var`にする
    // （実際に再代入することはない）
    var settings = MobileSettings()

    private(set) var isRecording = false
    private(set) var peerState: PeerClientState = .idle
    private(set) var pendingCount = 0
    private(set) var lastText = ""
    /// WatchRelayが現在扱っているWatch session（=収録）の数。ContentViewに「Watch: N stream」で出す
    private(set) var watchStreams = 0
    var lastError: String?

    private let outbox: Outbox
    private let recorder = Recorder()
    private var peerClient: PeerClient?
    private var watchRelay: WatchRelay?
    // `WCSession.delegate`はweak参照のため、こちらで強参照を保持し続ける必要がある
    private var watchSessionDelegate: WatchSessionDelegate?

    init() {
        outbox = Outbox(directory: Self.applicationSupportDirectory())
        // ペアリングコード未設定でもPeerClientは作っておく（`enqueue`がoutboxへのappendを
        // 兼ねるため、録音がペアリング前でも蓄積転送できるようにする）。browsingはコードが
        // あるときだけ始める
        connectPeer()
        connectWatch()
        Task { await self.refreshPendingCount() }
    }

    private static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Notetake", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Peer connection

    /// 現在の設定でPeerClientを(再)生成し、browsingを開始する
    private func connectPeer() {
        let hello = HelloMessage(
            device: settings.deviceID,
            deviceName: settings.deviceName,
            owner: settings.ownerName,
            platform: .ios
        )
        let box = WeakBox(self)
        let client = PeerClient(
            hello: hello,
            pairingCode: settings.pairingCode,
            outbox: outbox,
            onState: { state in
                Task { @MainActor in
                    guard let model = box.value else { return }
                    model.peerState = state
                    await model.refreshPendingCount()
                }
            }
        )
        peerClient = client
        if !settings.pairingCode.isEmpty {
            Task { await client.start() }
        }
    }

    /// ペアリングコード保存後に呼ぶ: 既存接続を止め、新しいコードで作り直す
    /// （PSKはPeerClientのinit時に固定されるため、コードが変わったら差し替える）
    func pairingCodeDidChange() {
        let previous = peerClient
        peerClient = nil
        peerState = .idle
        Task { await previous?.stop() }
        connectPeer()
    }

    // MARK: - Watch relay

    /// WatchRelayを起動し、`WCSession.isSupported()`ならdelegateを登録してactivateする。
    /// Watch非対応（実機がWatch非対応、または未ペアリング）の場合もrelay自体は作っておく
    /// （何も受信しないだけで無害。idleループが15秒おきに空のstreams辞書を見るだけ）。
    private func connectWatch() {
        let box = WeakBox(self)
        let relay = WatchRelay(
            locale: Self.locale,
            onSegment: { segment in
                // WatchRelay側のpieceTaskはこのclosureの完了をawaitしてから次のpieceへ進む
                // （WatchRelay.init参照）。ここで内側のTaskを`await`せず`Task { @MainActor in }`
                // だけ積んで即returnすると、複数segmentのMainActor移送がFIFO順で実行される保証が
                // 無くなり、outbox.nextSeq()の採番順が届いた順と食い違いうる（HANDOFFに残る
                // DaemonClientの同種の懸念と同じ問題）。そのためTaskの完了を待ちきる
                let task = Task { @MainActor in
                    guard let model = box.value else { return }
                    await model.handleWatchSegment(segment)
                }
                await task.value
            },
            onStreamCount: { count in
                Task { @MainActor in
                    box.value?.watchStreams = count
                }
            }
        )
        watchRelay = relay
        guard WCSession.isSupported() else { return }
        let delegate = WatchSessionDelegate(relay: relay)
        watchSessionDelegate = delegate
        WCSession.default.delegate = delegate
        WCSession.default.activate()
    }

    /// WatchRelayから届いたSegmentをoutboxへ積む。
    ///
    /// `segment.seq`はWatchRelay内では「そのWatch streamローカルな」連番でしかない。
    /// Outboxはこのiphone 1台につき1本の単調増加するseqカウンタしか持たないため
    /// （`nextSeq()` = ファイル中の最大seq + 1、deviceを区別しない）、ここで
    /// outbox全体のseqへ採番し直す。`device`はWatch自身のidのまま残す。
    ///
    /// Mac側はSegmentを`(device, seq)`でdedupし、deviceごとにseqのcursorを進める
    /// （`ack`はseqしか運ばない）。Watch deviceについて見えるseqは「iPhone全体seqの
    /// 部分列」になるが、部分列であっても厳密に単調増加である（一度採番したseqを
    /// 他のdeviceへ使い回すことはない）ため、Macの単調性チェック・重複排除・ack
    /// cursorの前進は壊れない。
    private func handleWatchSegment(_ segment: Segment) async {
        // seqの採番は`PeerClient.enqueue`→`Outbox.appendAssigningSeq`が原子的に行う
        await peerClient?.enqueue(segment)
        await refreshPendingCount()
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else { return }
        lastError = nil
        isRecording = true
        Task {
            do {
                try await Transcriber.ensureAssets(locale: Self.locale)
                let session = SessionStore.prefix(for: Date(), timeZone: .current)
                let box = WeakBox(self)
                try await self.recorder.start(locale: Self.locale) { piece, dbfs in
                    Task { @MainActor in
                        guard let model = box.value else { return }
                        await model.handleFinalPiece(piece, dbfs: dbfs, session: session)
                    }
                }
            } catch {
                self.isRecording = false
                self.lastError = "録音の開始に失敗しました: \(error.localizedDescription)"
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        Task {
            do {
                try await self.recorder.stop()
            } catch {
                self.lastError = "録音の停止に失敗しました: \(error.localizedDescription)"
            }
        }
    }

    private func handleFinalPiece(_ piece: TranscriptPiece, dbfs: Double, session: String) async {
        guard !piece.text.isEmpty else { return }
        lastText = piece.text
        // seqは`PeerClient.enqueue`→`Outbox.appendAssigningSeq`が原子的に採番する（ここでは0）
        let segment = Segment(
            id: UUID(),
            session: session,
            seq: 0,
            device: settings.deviceID,
            deviceName: settings.deviceName,
            owner: settings.ownerName,
            platform: .ios,
            source: .mic,
            input: InputDevice(name: "iPhone", uid: settings.deviceID, spatial: false),
            start: piece.startMS,
            end: piece.endMS,
            text: piece.text,
            confidence: piece.confidence,
            levelDBFS: dbfs
        )
        await peerClient?.enqueue(segment)
        await refreshPendingCount()
    }

    private func refreshPendingCount() async {
        pendingCount = (try? await outbox.pending())?.count ?? pendingCount
    }

    private static let locale = Locale(identifier: "ja-JP")
}
