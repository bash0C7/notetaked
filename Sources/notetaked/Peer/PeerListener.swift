import Foundation
import Network
import NotetakeCore

/// `PeerListener`内で発生順に振られる接続id
struct PeerConnectionID: Hashable, Sendable {
    let raw: Int
}

/// Bonjour（`_notetake._tcp`）でlistenし、TLS PSKで認証したTCP接続それぞれとNDJSON行を
/// やり取りするactor。NWのcallbackは全て専用queueから`Task { await self... }`でこのactorへ
/// hopする（callbackはNWの内部queueから呼ばれるため、actor isolation越しに直接触らない）。
actor PeerListener {
    private let pairingCode: String
    private let serviceName: String
    private let onMessage: @Sendable (PeerConnectionID, PeerMessage) async -> Void
    private let onDisconnect: @Sendable (PeerConnectionID) async -> Void
    /// NWListener/NWConnectionのcallbackを流す専用serial queue。
    /// `.main`は使わない: このプロセスはCLIのasync entry pointで動いており、
    /// 誰もCFRunLoop/dispatchMain()を回していないため`DispatchQueue.main`に積んだ
    /// callbackが実行されない（既存コードのSIGINT/SIGTERM handlerも同じ理由で`.global()`を使う）
    private let queue = DispatchQueue(label: "io.github.bash0c7.notetake.peer")

    private var listener: NWListener?
    private var connections: [PeerConnectionID: NWConnection] = [:]
    private var lineBuffers: [PeerConnectionID: LineBuffer] = [:]
    private var nextConnectionID = 1

    init(
        pairingCode: String,
        serviceName: String,
        onMessage: @escaping @Sendable (PeerConnectionID, PeerMessage) async -> Void,
        onDisconnect: @escaping @Sendable (PeerConnectionID) async -> Void
    ) {
        self.pairingCode = pairingCode
        self.serviceName = serviceName
        self.onMessage = onMessage
        self.onDisconnect = onDisconnect
    }

    func start() throws {
        let params = Self.makeParameters(pairingCode: pairingCode)
        let listener = try NWListener(using: params)
        listener.service = NWListener.Service(name: serviceName, type: "_notetake._tcp")

        listener.stateUpdateHandler = { state in
            FileHandle.standardError.write(Data("peer listener state: \(state)\n".utf8))
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.accept(connection) }
        }

        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        lineBuffers.removeAll()
    }

    func send(_ message: PeerMessage, to id: PeerConnectionID) {
        guard let connection = connections[id] else { return }
        sendLine(message, over: connection)
    }

    func broadcast(_ message: PeerMessage) {
        for connection in connections.values {
            sendLine(message, over: connection)
        }
    }

    // MARK: - per-connection

    private func accept(_ connection: NWConnection) {
        let id = PeerConnectionID(raw: nextConnectionID)
        nextConnectionID += 1
        connections[id] = connection
        lineBuffers[id] = LineBuffer()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                Task { await self.handleDisconnect(id) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveLoop(id: id, connection: connection)
    }

    private func receiveLoop(id: PeerConnectionID, connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task {
                if let data, !data.isEmpty {
                    await self.handleReceived(data, id: id)
                }
                if isComplete || error != nil {
                    await self.handleDisconnect(id)
                    return
                }
                await self.continueReceiving(id: id, connection: connection)
            }
        }
    }

    private func continueReceiving(id: PeerConnectionID, connection: NWConnection) {
        // disconnect済みなら receive を積み直さない
        guard connections[id] != nil else { return }
        receiveLoop(id: id, connection: connection)
    }

    private func handleReceived(_ data: Data, id: PeerConnectionID) async {
        guard var buffer = lineBuffers[id] else { return }
        let lines = buffer.append(data)
        lineBuffers[id] = buffer
        for line in lines {
            do {
                let message = try PeerMessage.decode(line: line)
                await onMessage(id, message)
            } catch {
                FileHandle.standardError.write(
                    Data("malformed peer line from \(id): \(line) (\(error))\n".utf8))
            }
        }
    }

    private func handleDisconnect(_ id: PeerConnectionID) async {
        guard let connection = connections[id] else { return }
        connection.cancel()
        connections[id] = nil
        lineBuffers[id] = nil
        await onDisconnect(id)
    }

    private func sendLine(_ message: PeerMessage, over connection: NWConnection) {
        guard let line = try? message.encodedLine() else { return }
        connection.send(content: Data((line + "\n").utf8), completion: .contentProcessed { _ in })
    }

    // MARK: - TLS PSK

    private static func makeParameters(pairingCode: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let psk = Data(pairingCode.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("notetake".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(
            tls.securityProtocolOptions, psk as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)

        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        params.includePeerToPeer = true
        return params
    }
}
