import Foundation
import Network

nonisolated enum DirectQuicStunCodecError: Error, LocalizedError, Equatable {
    case invalidHeader
    case invalidMessageLength
    case unexpectedMessageType(UInt16)
    case transactionIDMismatch
    case missingMappedAddress
    case unsupportedAddressFamily(UInt8)

    var errorDescription: String? {
        switch self {
        case .invalidHeader:
            return "invalid STUN header"
        case .invalidMessageLength:
            return "invalid STUN message length"
        case .unexpectedMessageType(let rawValue):
            return "unexpected STUN message type \(rawValue)"
        case .transactionIDMismatch:
            return "STUN transaction ID mismatch"
        case .missingMappedAddress:
            return "STUN response was missing a mapped address"
        case .unsupportedAddressFamily(let family):
            return "unsupported STUN address family \(family)"
        }
    }
}

nonisolated struct DirectQuicStunMappedAddress: Equatable {
    let address: String
    let port: Int
}

nonisolated enum DirectQuicStunCodec {
    static let bindingRequestType: UInt16 = 0x0001
    static let bindingSuccessResponseType: UInt16 = 0x0101
    static let magicCookie: UInt32 = 0x2112A442
    static let mappedAddressAttributeType: UInt16 = 0x0001
    static let xorMappedAddressAttributeType: UInt16 = 0x0020

    static func makeBindingRequest(transactionID: Data) -> Data {
        precondition(transactionID.count == 12)

        var data = Data(capacity: 20)
        data.append(contentsOf: bindingRequestType.networkBytes)
        data.append(contentsOf: UInt16(0).networkBytes)
        data.append(contentsOf: magicCookie.networkBytes)
        data.append(transactionID)
        return data
    }

    static func parseBindingResponse(
        _ data: Data,
        expectedTransactionID: Data
    ) throws -> DirectQuicStunMappedAddress {
        guard data.count >= 20 else {
            throw DirectQuicStunCodecError.invalidHeader
        }
        let messageType = data.readUInt16(at: 0)
        guard messageType == bindingSuccessResponseType else {
            throw DirectQuicStunCodecError.unexpectedMessageType(messageType)
        }
        let messageLength = Int(data.readUInt16(at: 2))
        guard data.count >= 20 + messageLength else {
            throw DirectQuicStunCodecError.invalidMessageLength
        }
        let magicCookie = data.readUInt32(at: 4)
        let transactionID = data.subdata(in: 8 ..< 20)
        guard transactionID == expectedTransactionID else {
            throw DirectQuicStunCodecError.transactionIDMismatch
        }

        var cursor = 20
        let messageEnd = 20 + messageLength
        while cursor + 4 <= messageEnd {
            let attributeType = data.readUInt16(at: cursor)
            let attributeLength = Int(data.readUInt16(at: cursor + 2))
            let valueStart = cursor + 4
            let valueEnd = valueStart + attributeLength
            guard valueEnd <= messageEnd else {
                throw DirectQuicStunCodecError.invalidMessageLength
            }
            let attributeValue = data.subdata(in: valueStart ..< valueEnd)

            switch attributeType {
            case xorMappedAddressAttributeType:
                return try parseAddressAttribute(
                    attributeValue,
                    xorEncoded: true,
                    magicCookie: magicCookie,
                    transactionID: transactionID
                )
            case mappedAddressAttributeType:
                return try parseAddressAttribute(
                    attributeValue,
                    xorEncoded: false,
                    magicCookie: magicCookie,
                    transactionID: transactionID
                )
            default:
                break
            }

            let paddedLength = ((attributeLength + 3) / 4) * 4
            cursor = valueStart + paddedLength
        }

        throw DirectQuicStunCodecError.missingMappedAddress
    }

    private static func parseAddressAttribute(
        _ value: Data,
        xorEncoded: Bool,
        magicCookie: UInt32,
        transactionID: Data
    ) throws -> DirectQuicStunMappedAddress {
        guard value.count >= 4 else {
            throw DirectQuicStunCodecError.invalidMessageLength
        }
        let family = value[1]
        let encodedPort = value.readUInt16(at: 2)
        let port: UInt16 = xorEncoded
            ? encodedPort ^ UInt16((magicCookie >> 16) & 0xFFFF)
            : encodedPort

        switch family {
        case 0x01:
            guard value.count >= 8 else {
                throw DirectQuicStunCodecError.invalidMessageLength
            }
            let encodedAddress = value.readUInt32(at: 4)
            let addressValue = xorEncoded
                ? encodedAddress ^ magicCookie
                : encodedAddress
            let octets = [
                UInt8((addressValue >> 24) & 0xFF),
                UInt8((addressValue >> 16) & 0xFF),
                UInt8((addressValue >> 8) & 0xFF),
                UInt8(addressValue & 0xFF),
            ]
            let address = octets.map(String.init).joined(separator: ".")
            return DirectQuicStunMappedAddress(address: address, port: Int(port))
        case 0x02:
            guard value.count >= 20 else {
                throw DirectQuicStunCodecError.invalidMessageLength
            }
            let mask = Data(magicCookie.networkBytes) + transactionID
            var addressBytes = [UInt8](value[4 ..< 20])
            if xorEncoded {
                for index in addressBytes.indices {
                    addressBytes[index] ^= mask[index]
                }
            }
            let address = addressBytes
                .chunked(into: 2)
                .map { chunk -> String in
                    let high = UInt16(chunk[0]) << 8
                    let low = UInt16(chunk[1])
                    return String(format: "%x", high | low)
                }
                .joined(separator: ":")
            return DirectQuicStunMappedAddress(address: address, port: Int(port))
        default:
            throw DirectQuicStunCodecError.unsupportedAddressFamily(family)
        }
    }
}

nonisolated enum DirectQuicStunClientError: Error, LocalizedError, Equatable {
    case invalidServerHost(String)
    case invalidServerPort(Int)
    case timeout
    case notConnected
    case noResponse
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidServerHost(let host):
            return "invalid STUN server host \(host)"
        case .invalidServerPort(let port):
            return "invalid STUN server port \(port)"
        case .timeout:
            return "STUN request timed out"
        case .notConnected:
            return "STUN connection was not ready"
        case .noResponse:
            return "STUN server did not return a response"
        case .connectionFailed(let message):
            return "STUN connection failed: \(message)"
        }
    }
}

nonisolated private final class DirectQuicStunContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasResumed = false

    func resume(_ operation: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResumed else { return }
        hasResumed = true
        operation()
    }
}

nonisolated final class DirectQuicStunClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Turbo.DirectQuicStun")
    private let timeoutMilliseconds: Int

    init(timeoutMilliseconds: Int = 1_500) {
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    func gatherServerReflexiveCandidates(
        localPort: UInt16,
        servers: [TurboDirectQuicStunServer]
    ) async -> [TurboDirectQuicCandidate] {
        guard !servers.isEmpty else { return [] }

        var seenAddresses = Set<String>()
        var candidates: [TurboDirectQuicCandidate] = []

        for (index, server) in servers.enumerated() {
            do {
                let mappedAddress = try await performBindingRequest(
                    server: server,
                    localPort: localPort
                )
                let dedupeKey = "\(mappedAddress.address):\(mappedAddress.port)"
                guard seenAddresses.insert(dedupeKey).inserted else { continue }
                candidates.append(
                    TurboDirectQuicCandidate(
                        foundation: "srflx-\(index)",
                        component: "media",
                        transport: "udp",
                        priority: max(900_000 - index, 1),
                        kind: .serverReflexive,
                        address: mappedAddress.address,
                        port: mappedAddress.port,
                        relatedAddress: "0.0.0.0",
                        relatedPort: Int(localPort)
                    )
                )
            } catch {
                continue
            }
        }

        return candidates
    }

    private func performBindingRequest(
        server: TurboDirectQuicStunServer,
        localPort: UInt16
    ) async throws -> DirectQuicStunMappedAddress {
        guard !server.host.isEmpty else {
            throw DirectQuicStunClientError.invalidServerHost(server.host)
        }
        let serverPortValue = server.port ?? 3478
        guard serverPortValue > 0,
              serverPortValue <= Int(UInt16.max),
              let serverPort = NWEndpoint.Port(rawValue: UInt16(serverPortValue)) else {
            throw DirectQuicStunClientError.invalidServerPort(serverPortValue)
        }

        let transactionID = Data((0..<12).map { _ in UInt8.random(in: 0 ... 255) })
        let request = DirectQuicStunCodec.makeBindingRequest(transactionID: transactionID)

        let parameters = NWParameters.udp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("0.0.0.0"),
            port: NWEndpoint.Port(rawValue: localPort) ?? .any
        )
        let connection = NWConnection(
            host: NWEndpoint.Host(server.host),
            port: serverPort,
            using: parameters
        )
        defer { connection.cancel() }

        try await waitForReady(connection)
        try await send(request, on: connection)
        let response = try await receive(on: connection)
        return try DirectQuicStunCodec.parseBindingResponse(
            response,
            expectedTransactionID: transactionID
        )
    }

    private func waitForReady(
        _ connection: NWConnection
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = DirectQuicStunContinuationGate()
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutMilliseconds) * 1_000_000)
                gate.resume {
                    connection.cancel()
                    continuation.resume(throwing: DirectQuicStunClientError.timeout)
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    timeoutTask.cancel()
                    gate.resume {
                        continuation.resume()
                    }
                case .failed(let error):
                    timeoutTask.cancel()
                    gate.resume {
                        continuation.resume(
                            throwing: DirectQuicStunClientError.connectionFailed(
                                error.localizedDescription
                            )
                        )
                    }
                case .cancelled:
                    timeoutTask.cancel()
                    gate.resume {
                        continuation.resume(throwing: DirectQuicStunClientError.notConnected)
                    }
                case .waiting(let error):
                    timeoutTask.cancel()
                    gate.resume {
                        continuation.resume(
                            throwing: DirectQuicStunClientError.connectionFailed(
                                error.localizedDescription
                            )
                        )
                    }
                case .setup, .preparing:
                    break
                @unknown default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }

    private func send(
        _ data: Data,
        on connection: NWConnection
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(
                        throwing: DirectQuicStunClientError.connectionFailed(
                            error.localizedDescription
                        )
                    )
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receive(
        on connection: NWConnection
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let gate = DirectQuicStunContinuationGate()
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutMilliseconds) * 1_000_000)
                gate.resume {
                    connection.cancel()
                    continuation.resume(throwing: DirectQuicStunClientError.timeout)
                }
            }

            connection.receiveMessage { data, _, _, error in
                timeoutTask.cancel()
                if let error {
                    gate.resume {
                        continuation.resume(
                            throwing: DirectQuicStunClientError.connectionFailed(
                                error.localizedDescription
                            )
                        )
                    }
                    return
                }
                guard let data, !data.isEmpty else {
                    gate.resume {
                        continuation.resume(throwing: DirectQuicStunClientError.noResponse)
                    }
                    return
                }
                gate.resume {
                    continuation.resume(returning: data)
                }
            }
        }
    }
}

nonisolated private extension FixedWidthInteger {
    var networkBytes: [UInt8] {
        withUnsafeBytes(of: self.bigEndian, Array.init)
    }
}

nonisolated private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        let upper = UInt16(self[offset]) << 8
        let lower = UInt16(self[offset + 1])
        return upper | lower
    }

    func readUInt32(at offset: Int) -> UInt32 {
        let b0 = UInt32(self[offset]) << 24
        let b1 = UInt32(self[offset + 1]) << 16
        let b2 = UInt32(self[offset + 2]) << 8
        let b3 = UInt32(self[offset + 3])
        return b0 | b1 | b2 | b3
    }
}

nonisolated private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
