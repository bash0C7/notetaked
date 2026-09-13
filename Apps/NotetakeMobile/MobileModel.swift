import Foundation
import NotetakeCore

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
    var lastError: String?

    private let outbox: Outbox
    private let recorder = Recorder()
    private var peerClient: PeerClient?

    init() {
        outbox = Outbox(directory: Self.applicationSupportDirectory())
        // ペアリングコード未設定でもPeerClientは作っておく（`enqueue`がoutboxへのappendを
        // 兼ねるため、録音がペアリング前でも蓄積転送できるようにする）。browsingはコードが
        // あるときだけ始める
        connectPeer()
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
        let seq = await outbox.nextSeq()
        let segment = Segment(
            id: UUID(),
            session: session,
            seq: seq,
            device: settings.deviceID,
            deviceName: settings.deviceName,
            owner: settings.ownerName,
            platform: .ios,
            source: .mic,
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
