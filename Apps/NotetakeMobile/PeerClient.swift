import Dispatch
import Foundation
import Network
import NotetakeCore

/// PeerClientの現在状態。ライブなUI表示に使う
enum PeerClientState: Sendable, Equatable {
    case idle
    case browsing
    case connecting(String)
    case connected(String)
    case failed(String)
}

/// iPhone→Mac接続。Bonjour(`_notetake._tcp`)で発見しTLS(PSK)で接続、`Outbox`の内容をNDJSONで送る。
/// 切断時はbrowserを立て直すことで再接続する（backoff: 1s,2s,4s,...最大30s）
actor PeerClient {
    private let hello: HelloMessage
    private let pairingCode: String
    private let outbox: Outbox
    private let onState: @Sendable (PeerClientState) -> Void
    /// ackの後に未送信の件数を数え直すため。ackされたseqを渡す
    private let onAck: @Sendable (Int) -> Void
    private let queue = DispatchQueue(label: "io.github.bash0c7.notetake.peer")

    private var browser: NWBrowser?
    private var connection: NWConnection?
    /// 再接続の逐次の手順（直接 → browse）。同時に2本の接続は持たない
    private var reconnect = PeerReconnect()
    /// 最後に`.ready`になった接続の相手の端点。wake時にまず直接つなぐ。直接が失敗したら捨てる
    /// （Macのport等が変わりうる）。メモリにだけ持つので、cold launch直後は使えない
    private var savedEndpoint: NWEndpoint?
    private var directTimeoutTask: Task<Void, Never>?
    private var connectStartedAt = Date()
    private var connectKind = "browse"
    /// 現在の状態（browsing / connecting等）に入った時刻。`wake()`が止まった試行を見分ける
    private var stateEnteredAt = Date()
    /// appが最後に背面へ回った時刻。これより前に始まった試行はsuspendをまたいでいる
    private var lastBackgroundedAt: Date = .distantPast
    private static let connectionTimeoutSeconds = 5
    private static let directTimeoutSeconds: Double = 3
    private var receiveBuffer = Data()
    private var reconnectTask: Task<Void, Never>?
    private var backoffSeconds: Double = 1
    private var stopped = true
    /// 再接続のbackoffを待っている間。`wake()`が待ちを取り消して今すぐ探すかを決めるのに使う
    private var waitingToRetry = false

    /// `.waiting`が連続何回観測されたか。ネットワーク変更で到達不能になった接続は
    /// `.failed`ではなく`.waiting`のまま留まることが多いため、これが閾値に達したら
    /// `.failed`と同様に扱い再接続する（issue #11）
    private var consecutiveWaitingCount = 0
    private static let waitingThreshold = 3

    /// 最後に何か（helloAck/ping/ack等）を受信した時刻。Macは接続中60秒毎にpingを送り続けるため、
    /// これが一定時間更新されなければ相手が死んでいる（daemon再起動等でTCPのFINが来ない/遅れる場合の
    /// 保険）と見なし再接続する（issue #7）
    private var lastActivityAt: Date = .distantPast
    private var watchdogTask: Task<Void, Never>?
    private static let watchdogTimeoutSeconds: Double = 150
    private static let watchdogCheckIntervalSeconds: Double = 30

    private var state: PeerClientState = .idle {
        didSet {
            // 実機の接続不良を`devicectl device process launch --console`で追えるようstderrへ出す
            Diag.log("peer client: \(state)")
            let from = Self.kind(of: oldValue)
            let to = Self.kind(of: state)
            if from != to {
                var reason: String?
                if case .failed(let text) = state { reason = text }
                RelayTrace.record(
                    .peerState, detail: RelayTraceRecord.peerStateDetail(from: from, to: to, reason: reason))
            }
            onState(state)
        }
    }

    init(
        hello: HelloMessage,
        pairingCode: String,
        outbox: Outbox,
        onState: @escaping @Sendable (PeerClientState) -> Void,
        onAck: @escaping @Sendable (Int) -> Void
    ) {
        self.hello = hello
        self.pairingCode = pairingCode
        self.outbox = outbox
        self.onState = onState
        self.onAck = onAck
    }

    /// browsingを開始する。既に動いていれば何もしない
    func start() {
        guard stopped else { return }
        stopped = false
        backoffSeconds = 1
        startAttempt(allowDirect: false)
    }

    /// browser/connection/再接続待ちを全て止め、`.idle`にする
    func stop() {
        stopped = true
        reconnectTask?.cancel()
        reconnectTask = nil
        waitingToRetry = false
        watchdogTask?.cancel()
        watchdogTask = nil
        tearDownAttempt()
        reconnect.stop()
        state = .idle
    }

    /// appが背面へ回った。この前から続く試行は、suspendの間に止まっているかもしれない
    func noteBackgrounded() {
        lastBackgroundedAt = Date()
    }

    /// outbox全体のseqを採番してappendし（`Outbox.appendAssigningSeq`、actor内で原子的）、
    /// 接続中ならそのまま`.seg`として送る。呼び出し側の`segment.seq`は無視される
    /// 採番したseqを返す（appendに失敗したらnil）
    @discardableResult
    func enqueue(_ segment: Segment) async -> Int? {
        let sequenced: Segment
        do {
            sequenced = try await outbox.appendAssigningSeq(segment)
        } catch {
            return nil
        }
        if case .connected = state {
            send(.seg(sequenced))
        }
        return sequenced.seq
    }

    /// Watchの状態をMacへ送る。接続中だけ送る（間引きは呼び出し側）
    func sendWatchStatus(_ snapshot: WatchStatusSnapshot) {
        guard case .connected = state else { return }
        send(.watchStatus(snapshot))
    }

    /// Watchの合図で背面に起こされた時に呼ぶ。suspendの間は再接続のbackoff（最大30秒）とwatchdogの時計が
    /// 止まっているので、待たずにつなぎ直す。判断は`PeerWakePolicy`
    func wake() {
        let link: PeerWakePolicy.Link
        if stopped {
            link = .stopped
        } else if connection != nil, case .connected = state {
            link = .connected(lastActivityAgeMS: Int64(Date().timeIntervalSince(lastActivityAt) * 1000))
        } else if waitingToRetry {
            link = .waitingToRetry
        } else {
            link = .attempting(
                ageMS: Int64(Date().timeIntervalSince(stateEnteredAt) * 1000),
                crossedSuspend: stateEnteredAt < lastBackgroundedAt)
        }
        let decision = PeerWakePolicy.onWake(link)
        RelayTrace.record(.wakeDecision, detail: RelayTraceRecord.wakeDecisionDetail(link, decision))
        switch decision {
        case .none:
            break
        case .connectNow, .reconnectNow:
            connectNowResettingBackoff()
        }
    }

    /// backoffの待ちを取り消し、backoffを初期値へ戻し、動いているbrowser / connectionを確実に捨てて、
    /// 直接 → browseの順でつなぎ直す
    private func connectNowResettingBackoff() {
        reconnectTask?.cancel()
        reconnectTask = nil
        waitingToRetry = false
        backoffSeconds = 1
        startAttempt(allowDirect: true)
    }

    /// 進んでいるbrowser / connection / 直接接続の時間制限を全て止める。古いconnectionのcallbackは
    /// `connection ===`の判定で無視される
    private func tearDownAttempt() {
        directTimeoutTask?.cancel()
        directTimeoutTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll()
        consecutiveWaitingCount = 0
    }

    private func startAttempt(allowDirect: Bool) {
        guard !stopped else { return }
        tearDownAttempt()
        switch reconnect.start(allowDirect: allowDirect) {
        case .connectDirect:
            guard let endpoint = savedEndpoint else {
                _ = reconnect.directFailed()
                startBrowsing()
                return
            }
            connect(to: endpoint, kind: "direct")
            directTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.directTimeoutSeconds))
                if Task.isCancelled { return }
                await self?.directTimedOut()
            }
        default:
            startBrowsing()
        }
    }

    private func directTimedOut() {
        guard reconnect.phase == .direct, connection != nil else { return }
        Diag.log("peer client: direct connect timed out")
        fallBackToBrowse()
    }

    /// 直接接続をやめてbrowseへ進む。端点は捨てる（次の`.ready`で取り直す）
    private func fallBackToBrowse() {
        directTimeoutTask?.cancel()
        directTimeoutTask = nil
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll()
        savedEndpoint = nil
        _ = reconnect.directFailed()
        startBrowsing()
    }

    private static func kind(of state: PeerClientState) -> String {
        switch state {
        case .idle: return "idle"
        case .browsing: return "browsing"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .failed: return "failed"
        }
    }

    // MARK: - Browsing

    private func startBrowsing() {
        guard !stopped else { return }
        // 残っているbrowserが後から`.failed`になって、つないだ接続の状態を上書きしないよう先に捨てる
        browser?.cancel()
        browser = nil
        // 同じ種類の状態へ作り直しても、経過時間を数え直す（didSetの種類比較に頼らない）
        stateEnteredAt = Date()
        state = .browsing
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_notetake._tcp", domain: nil), using: parameters)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            Task { await self.handleBrowserState(newState, from: browser) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let first = results.first?.endpoint
            let count = results.count
            Task { await self.handleBrowseResult(first, count: count, from: browser) }
        }
        browser.start(queue: queue)
    }

    private func handleBrowserState(_ newState: NWBrowser.State, from source: NWBrowser) {
        // 捨てた古いbrowserのcallbackは無視する
        guard browser === source else { return }
        switch newState {
        case .failed:
            browser?.cancel()
            browser = nil
            guard !stopped else {
                state = .idle
                return
            }
            state = .failed("\(newState)")
            reconnect.stop()
            scheduleReconnect()
        default:
            break
        }
    }

    private func handleBrowseResult(_ endpoint: NWEndpoint?, count: Int, from source: NWBrowser) {
        guard browser === source else { return }
        RelayTrace.record(
            .browseResult,
            detail: RelayTraceRecord.browseResultDetail(count: count, chosen: endpoint.map { "\($0)" }))
        guard !stopped, let endpoint, connection == nil, reconnect.browseFound() == .connectBrowsed else { return }
        browser?.cancel()
        browser = nil
        connect(to: endpoint, kind: "browse")
    }

    // MARK: - Connecting

    private func connect(to endpoint: NWEndpoint, kind: String) {
        let description = Self.describe(endpoint)
        Diag.log("peer client: connect to \(endpoint) (\(kind))")
        RelayTrace.record(
            .connectStarted, detail: RelayTraceRecord.connectStartedDetail(endpoint: "\(endpoint)", kind: kind))
        connectStartedAt = Date()
        connectKind = kind
        stateEnteredAt = Date()
        state = .connecting(description)

        let tls = NWProtocolTLS.Options()
        let pskData = Data(pairingCode.utf8)
        let identityData = Data("notetake".utf8)
        let pskDispatchData = pskData.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityDispatchData = identityData.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(
            tls.securityProtocolOptions, pskDispatchData as __DispatchData,
            identityDispatchData as __DispatchData)
        guard
            let ciphersuite = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))
        else {
            state = .failed("unsupported ciphersuite")
            scheduleReconnect()
            return
        }
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, ciphersuite)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)

        // 背面で`.preparing`のまま進まない接続を、OSの既定（長い待ち）に任せず短く打ち切る
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Self.connectionTimeoutSeconds
        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true

        let connection = NWConnection(to: endpoint, using: params)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            Task { await self.handleConnectionState(newState, on: connection, description: description) }
        }
        connection.start(queue: queue)
    }

    private func handleConnectionState(
        _ newState: NWConnection.State, on connection: NWConnection, description: String
    ) async {
        // 既に別の接続に切り替わっている（古いconnectionのcallback。`wake()`で捨てた接続の`.cancelled`など）
        // 場合は無視する。さもないと新しい接続を切ってしまう
        guard self.connection === connection else { return }
        switch newState {
        case .ready:
            reconnect.ready()
            directTimeoutTask?.cancel()
            directTimeoutTask = nil
            // 接続できたら、残っているbrowserは要らない（後から`.failed`になって接続の状態を壊さないよう捨てる）
            browser?.cancel()
            browser = nil
            RelayTrace.record(
                .connectReady,
                detail: RelayTraceRecord.connectReadyDetail(
                    elapsedMS: Int64(Date().timeIntervalSince(connectStartedAt) * 1000),
                    interface: connection.currentPath?.availableInterfaces.first?.name, kind: connectKind))
            if let remote = connection.currentPath?.remoteEndpoint {
                savedEndpoint = remote
                reconnect.endpointSaved()
            }
            consecutiveWaitingCount = 0
            lastActivityAt = Date()
            startWatchdog()
            state = .connected(description)
            backoffSeconds = 1
            send(.hello(hello))
            startReceiving()
            await resendPending()
        case .waiting(let error):
            Diag.log("peer client: waiting \(error)")
            consecutiveWaitingCount += 1
            if consecutiveWaitingCount >= Self.waitingThreshold {
                consecutiveWaitingCount = 0
                handleDisconnect(reason: "\(error)")
            }
        case .failed(let error):
            handleDisconnect(reason: "\(error)")
        case .cancelled:
            handleDisconnect(reason: "cancelled")
        default:
            break
        }
    }

    private func handleDisconnect(reason: String) {
        guard let current = connection else { return }
        // `.failed`の接続も必ずcancelする（stateUpdateHandlerの強参照の循環を残さない）
        current.cancel()
        directTimeoutTask?.cancel()
        directTimeoutTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        connection = nil
        receiveBuffer.removeAll()
        consecutiveWaitingCount = 0
        guard !stopped else {
            reconnect.stop()
            state = .idle
            return
        }
        switch reconnect.connectionFailed() {
        case .startBrowse:
            // 直接接続の失敗。端点を捨てて、backoffを挟まずbrowseへ進む
            savedEndpoint = nil
            startBrowsing()
        case .scheduleBackoff, .connectDirect, .connectBrowsed:
            // 既により具体的な理由（helloの拒否など）が設定済みならそれを残す
            if case .failed = state {
                // keep
            } else {
                state = .failed(reason)
            }
            scheduleReconnect()
        case .ignore:
            break
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        waitingToRetry = true
        let delay = backoffSeconds
        backoffSeconds = min(backoffSeconds * 2, 30)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            await self.restartAfterBackoff()
        }
    }

    private func restartAfterBackoff() {
        waitingToRetry = false
        guard !stopped else { return }
        startAttempt(allowDirect: false)
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.watchdogCheckIntervalSeconds))
                if Task.isCancelled { return }
                guard let self else { return }
                await self.checkWatchdog()
            }
        }
    }

    private func checkWatchdog() {
        guard connection != nil else { return }
        guard Date().timeIntervalSince(lastActivityAt) > Self.watchdogTimeoutSeconds else { return }
        Diag.log("peer client: watchdog timeout, no activity for \(Self.watchdogTimeoutSeconds)s")
        handleDisconnect(reason: "watchdog timeout")
    }

    // MARK: - Receiving

    private func startReceiving() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { await self.handleReceive(data: data, isComplete: isComplete, error: error, on: connection) }
        }
    }

    private func handleReceive(
        data: Data?, isComplete: Bool, error: NWError?, on connection: NWConnection
    ) async {
        // 既に別の接続に切り替わっている（古いconnectionのcallback）場合は無視
        guard self.connection === connection else { return }

        if let data, !data.isEmpty {
            receiveBuffer.append(data)
            await processBufferedLines()
        }
        if let error {
            handleDisconnect(reason: "\(error)")
            return
        }
        if isComplete {
            handleDisconnect(reason: "connection closed")
            return
        }
        startReceiving()
    }

    private func processBufferedLines() async {
        while let newlineIndex = receiveBuffer.firstIndex(of: 0x0A) {
            let lineData = receiveBuffer.subdata(in: receiveBuffer.startIndex..<newlineIndex)
            receiveBuffer.removeSubrange(receiveBuffer.startIndex...newlineIndex)
            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
            guard let message = try? PeerMessage.decode(line: line) else { continue }
            await handleMessage(message)
        }
    }

    private func handleMessage(_ message: PeerMessage) async {
        lastActivityAt = Date()
        switch message {
        case .helloAck(let ack):
            if !ack.accepted {
                state = .failed(ack.reason ?? "rejected")
                connection?.cancel()
            }
        case .ping(let id, let t0):
            let t1 = Self.nowMS()
            send(.pong(id: id, t0: t0, t1: t1, t2: Self.nowMS()))
        case .ack(let seq):
            try? await outbox.acknowledge(upTo: seq)
            _ = try? await outbox.compactIfDrained()
            onAck(seq)
        default:
            break
        }
    }

    // MARK: - Sending

    private func send(_ message: PeerMessage) {
        guard let connection else { return }
        guard let line = try? message.encodedLine() else { return }
        connection.send(content: Data((line + "\n").utf8), completion: .contentProcessed { _ in })
    }

    private func resendPending() async {
        guard let pending = try? await outbox.pending() else { return }
        for segment in pending {
            send(.seg(segment))
        }
    }

    // MARK: - Helpers

    private static func describe(_ endpoint: NWEndpoint) -> String {
        if case let .service(name, _, _, _) = endpoint {
            return name
        }
        return "\(endpoint)"
    }

    private static func nowMS() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }
}
