import Foundation
@preconcurrency import Network

@MainActor
final class FramedConnection {
    let connection: NWConnection

    var onMessage: ((WireMessage) -> Void)?
    var onStateChange: ((NWConnection.State) -> Void)?
    var onProtocolError: ((Error) -> Void)?

    private var receiveBuffer = Data()
    private var started = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        guard !started else { return }
        started = true

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.onStateChange?(state)
            }
        }
        receiveNextChunk()
        connection.start(queue: .global(qos: .userInitiated))
    }

    func send(_ message: WireMessage) throws {
        let payload = try WireCodec.encoder.encode(message)
        guard payload.count <= PairingProtocol.maximumFrameSize else {
            throw PairingProtocolError.frameTooLarge
        }

        var networkLength = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &networkLength) { Data($0) }
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.onProtocolError?(error)
            }
        })
    }

    func cancel() {
        connection.stateUpdateHandler = nil
        connection.cancel()
        started = false
        receiveBuffer.removeAll(keepingCapacity: false)
    }

    private func receiveNextChunk() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] content, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let content {
                    self.receiveBuffer.append(content)
                    self.processFrames()
                }

                if let error {
                    self.onProtocolError?(error)
                    return
                }
                if isComplete {
                    return
                }
                self.receiveNextChunk()
            }
        }
    }

    private func processFrames() {
        while receiveBuffer.count >= MemoryLayout<UInt32>.size {
            let networkLength = receiveBuffer.prefix(4).withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self)
            }
            let payloadLength = Int(UInt32(bigEndian: networkLength))

            guard payloadLength <= PairingProtocol.maximumFrameSize else {
                onProtocolError?(PairingProtocolError.frameTooLarge)
                cancel()
                return
            }

            let frameLength = MemoryLayout<UInt32>.size + payloadLength
            guard receiveBuffer.count >= frameLength else { return }

            let payload = receiveBuffer.subdata(in: 4..<frameLength)
            receiveBuffer.removeSubrange(0..<frameLength)

            do {
                onMessage?(try WireCodec.decoder.decode(WireMessage.self, from: payload))
            } catch {
                onProtocolError?(PairingProtocolError.invalidFrame)
                cancel()
                return
            }
        }
    }
}
