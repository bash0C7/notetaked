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
    private let queue = DispatchQueue(label: "io.github.bash0c7.notetake.peer")

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var reconnectTask: Task<Void, Never>?
    private var backoffSeconds: Double = 1
    private var stopped = true

    private var state: PeerClientState = .idle {
        didSet { onState(state) }
    }

    init(
        hello: HelloMessage,
        pairingCode: String,
        outbox: Outbox,
        onState: @escaping @Sendable (PeerClientState) -> Void
    ) {
        self.hello = hello
        self.pairingCode = pairingCode
        self.outbox = outbox
        self.onState = onState
    }

    /// browsingを開始する。既に動いていれば何もしない
    func start() {
        guard stopped else { return }
        stopped = false
        backoffSeconds = 1
        startBrowsing()
    }

    /// browser/connection/再接続待ちを全て止め、`.idle`にする
    func stop() {
        stopped = true
        reconnectTask?.cancel()
        reconnectTask = nil
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll()
        state = .idle
    }

    /// outbox全体のseqを採番してappendし（`Outbox.appendAssigningSeq`、actor内で原子的）、
    /// 接続中ならそのまま`.seg`として送る。呼び出し側の`segment.seq`は無視される
    func enqueue(_ segment: Segment) async {
        let sequenced: Segment
        do {
            sequenced = try await outbox.appendAssigningSeq(segment)
        } catch {
            return
        }
        if case .connected = state {
            send(.seg(sequenced))
        }
    }

    // MARK: - Browsing

    private func startBrowsing() {
        guard !stopped else { return }
        state = .browsing
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_notetake._tcp", domain: nil), using: parameters)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            Task { await self.handleBrowserState(newState) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            guard let first = results.first else { return }
            Task { await self.handleBrowseResult(first.endpoint) }
        }
        browser.start(queue: queue)
    }

    private func handleBrowserState(_ newState: NWBrowser.State) {
        switch newState {
        case .failed:
            browser?.cancel()
            browser = nil
            guard !stopped else {
                state = .idle
                return
            }
            state = .failed("\(newState)")
            scheduleReconnect()
        default:
            break
        }
    }

    private func handleBrowseResult(_ endpoint: NWEndpoint) {
        guard !stopped, connection == nil else { return }
        browser?.cancel()
        browser = nil
        connect(to: endpoint)
    }

    // MARK: - Connecting

    private func connect(to endpoint: NWEndpoint) {
        let description = Self.describe(endpoint)
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

        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        params.includePeerToPeer = true

        let connection = NWConnection(to: endpoint, using: params)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            Task { await self.handleConnectionState(newState, description: description) }
        }
        connection.start(queue: queue)
    }

    private func handleConnectionState(_ newState: NWConnection.State, description: String) async {
        switch newState {
        case .ready:
            state = .connected(description)
            backoffSeconds = 1
            send(.hello(hello))
            startReceiving()
            await resendPending()
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
        current.cancel()
        connection = nil
        receiveBuffer.removeAll()
        guard !stopped else {
            state = .idle
            return
        }
        // 既により具体的な理由（helloの拒否など）が設定済みならそれを残す
        if case .failed = state {
            // keep
        } else {
            state = .failed(reason)
        }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let delay = backoffSeconds
        backoffSeconds = min(backoffSeconds * 2, 30)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            await self.restartAfterBackoff()
        }
    }

    private func restartAfterBackoff() {
        guard !stopped else { return }
        startBrowsing()
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
