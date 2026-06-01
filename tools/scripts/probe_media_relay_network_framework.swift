import Foundation
import Network
import Security

let host = CommandLine.arguments.dropFirst().first ?? "relay.beepbeep.to"
let port = NWEndpoint.Port(rawValue: UInt16(CommandLine.arguments.dropFirst(2).first ?? "443") ?? 443) ?? .https
let queue = DispatchQueue(label: "turbo.media-relay.network-framework-probe")
let done = DispatchSemaphore(value: 0)
var didFinish = false

func finish(_ message: String) {
    queue.async {
        guard !didFinish else { return }
        didFinish = true
        print(message)
        done.signal()
    }
}

let quicOptions = NWProtocolQUIC.Options(alpn: ["turbo-relay-v2"])
sec_protocol_options_set_min_tls_protocol_version(
    quicOptions.securityProtocolOptions,
    .TLSv13
)
quicOptions.idleTimeout = 10_000
quicOptions.isDatagram = true
quicOptions.maxDatagramFrameSize = 4096

let connection = NWConnection(
    host: NWEndpoint.Host(host),
    port: port,
    using: NWParameters(quic: quicOptions)
)

func receiveDatagramAck() {
    connection.receiveMessage { data, _, _, error in
        if let error {
            finish("receive_error=\(error)")
            return
        }
        guard let data, !data.isEmpty else {
            receiveDatagramAck()
            return
        }
        let text = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
        finish("datagram_join_ack=\(text)")
    }
}

func sendDatagramJoin() {
    let frame: [String: String] = [
        "type": "datagram-join",
        "session_id": "network-framework-probe-session",
        "device_id": "network-framework-probe-device-a",
        "peer_device_id": "network-framework-probe-device-b",
        "token": ""
    ]
    do {
        let data = try JSONSerialization.data(withJSONObject: frame)
        print("datagram_max_size=\(connection.maximumDatagramSize)")
        connection.send(
            content: data,
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { error in
                if let error {
                    finish("send_error=\(error)")
                } else {
                    print("send_processed=true")
                }
            }
        )
    } catch {
        finish("encode_error=\(error)")
    }
}

connection.stateUpdateHandler = { state in
    switch state {
    case .ready:
        print("state=ready endpoint=\(host):\(port)")
        receiveDatagramAck()
        sendDatagramJoin()
    case .waiting(let error):
        print("state=waiting error=\(error)")
    case .failed(let error):
        finish("state=failed error=\(error)")
    case .cancelled:
        finish("state=cancelled")
    case .setup, .preparing:
        break
    @unknown default:
        break
    }
}

connection.start(queue: queue)

queue.asyncAfter(deadline: .now() + .seconds(5)) {
    finish("timeout=datagram_join_ack")
    connection.cancel()
}

_ = done.wait(timeout: .now() + .seconds(6))
connection.cancel()
