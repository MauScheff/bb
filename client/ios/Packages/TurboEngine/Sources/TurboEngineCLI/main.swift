import Foundation
import TurboEngine
import TurboEngineSimulation

@main
struct TurboEngineCommand {
    static func main() async {
        do {
            try await run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("turbo-engine: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func run(arguments: [String]) async throws {
        guard let command = arguments.first else {
            printHelp()
            return
        }
        let runner = EngineScenarioRunner()
        switch command {
        case "scenario":
            let name = arguments.dropFirst().first ?? "foreground_transmit_receive"
            let report = try await runner.run(name: name)
            try printJSON(report)
            guard report.passed else { Foundation.exit(2) }

        case "scenario-local":
            let name = arguments.dropFirst().first ?? "foreground_transmit_receive"
            let base = URL(string: arguments.dropFirst(2).first ?? "http://localhost:8090/s/turbo")!
            let backend = LiveHTTPWebSocketEngineBackendPort(
                baseURL: base,
                handle: "@avery",
                deviceID: "engine-local-avery",
                peerHandle: "@blake",
                peerDeviceID: "engine-local-blake"
            )
            let report = try await runner.run(name: name, backend: backend)
            try printJSON(report)
            guard report.passed else { Foundation.exit(2) }

        case "scenario-diff-local":
            let name = arguments.dropFirst().first ?? "foreground_transmit_receive"
            let base = URL(string: arguments.dropFirst(2).first ?? "http://localhost:8090/s/turbo")!
            let liveBackend = LiveHTTPWebSocketEngineBackendPort(
                baseURL: base,
                handle: "@avery",
                deviceID: "engine-local-avery",
                peerHandle: "@blake",
                peerDeviceID: "engine-local-blake"
            )
            try await liveBackend.connectWebSocket()
            let inMemory = try await runner.run(name: name, backend: InMemoryEngineBackendPort())
            let liveLocal = try await runner.run(name: name, backend: liveBackend)
            let report = EngineScenarioDifferentialReport(
                name: name,
                inMemory: inMemory,
                liveLocal: liveLocal
            )
            try printJSON(report)
            guard report.passed else { Foundation.exit(2) }

        case "fuzz":
            let seed = UInt64(arguments.dropFirst().first ?? "1") ?? 1
            let count = Int(arguments.dropFirst(2).first ?? "10") ?? 10
            let reports = try await runner.fuzz(seed: seed, count: count)
            let artifact = try writeFuzzArtifact(seed: seed, reports: reports)
            try printJSON(FuzzSummary(seed: seed, count: count, artifactPath: artifact.path, reports: reports))
            guard reports.allSatisfy(\.passed) else { Foundation.exit(2) }

        case "fuzz-local":
            let seed = UInt64(arguments.dropFirst().first ?? "1") ?? 1
            let count = Int(arguments.dropFirst(2).first ?? "10") ?? 10
            let base = URL(string: arguments.dropFirst(3).first ?? "http://localhost:8090/s/turbo")!
            let backend = LiveHTTPWebSocketEngineBackendPort(
                baseURL: base,
                handle: "@avery",
                deviceID: "engine-local-avery",
                peerHandle: "@blake",
                peerDeviceID: "engine-local-blake"
            )
            try await backend.connectWebSocket()
            let reports = try await runner.fuzz(seed: seed, count: count, backend: backend)
            let artifact = try writeFuzzArtifact(seed: seed, reports: reports)
            try printJSON(FuzzSummary(seed: seed, count: count, artifactPath: artifact.path, reports: reports))
            guard reports.allSatisfy(\.passed) else { Foundation.exit(2) }

        case "fuzz-corpus":
            let path = arguments.dropFirst().first ?? "client/ios/Packages/TurboEngine/Fixtures/fuzz-corpus.json"
            let corpus = try readFuzzCorpus(path: path)
            var reports: [EngineScenarioReport] = []
            for item in corpus.cases {
                reports.append(try await runner.run(name: item.name))
            }
            let summary = FuzzCorpusSummary(
                path: path,
                count: reports.count,
                reports: reports
            )
            try printJSON(summary)
            guard reports.allSatisfy(\.passed) else { Foundation.exit(2) }

        case "trace-replay":
            guard let path = arguments.dropFirst().first else {
                throw CommandError.missingArgument("trace-replay requires an EngineTrace JSON path")
            }
            let trace = try readEngineTrace(path: path)
            let report = EngineTraceReplayer.replay(trace)
            try printJSON(EngineTraceReplayCLIReport(report))
            guard report.passed else { Foundation.exit(2) }

        case "trace-normalize":
            guard let path = arguments.dropFirst().first else {
                throw CommandError.missingArgument("trace-normalize requires an EngineTrace JSON path")
            }
            let trace = try readEngineTrace(path: path)
            try printJSON(EngineTraceReplayer.normalizedTrace(trace))

        case "help", "--help", "-h":
            printHelp()

        default:
            throw CommandError.unknownCommand(command)
        }
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func writeFuzzArtifact(seed: UInt64, reports: [EngineScenarioReport]) throws -> URL {
        let directory = URL(fileURLWithPath: "/tmp/turbo-engine-fuzz", isDirectory: true)
            .appendingPathComponent("seed-\(seed)-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("result.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(reports).write(to: artifact)
        return artifact
    }

    private static func readEngineTrace(path: String) throws -> EngineTrace {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        do {
            let trace = try decoder.decode(EngineTrace.self, from: data)
            return trace
        } catch {
            let envelope = try decoder.decode(EngineTraceEnvelope.self, from: data)
            guard let trace = envelope.engineTrace else {
                throw CommandError.invalidArtifact("artifact did not contain an EngineTrace or engineTrace field")
            }
            return trace
        }
    }

    private static func readFuzzCorpus(path: String) throws -> EngineFuzzCorpus {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(EngineFuzzCorpus.self, from: data)
    }

    private static func printHelp() {
        print(
            """
            Usage:
              turbo-engine scenario [name]
              turbo-engine scenario fuzz_case:<seed>:<index>
              turbo-engine scenario-local [name] [base-url]
              turbo-engine scenario-diff-local [name] [base-url]
              turbo-engine fuzz [seed] [count]
              turbo-engine fuzz-local [seed] [count] [base-url]
              turbo-engine fuzz-corpus [path]
              turbo-engine trace-replay <trace-or-diagnostics-json>
              turbo-engine trace-normalize <trace-or-diagnostics-json>
            """
        )
    }
}

private enum CommandError: Error, LocalizedError {
    case unknownCommand(String)
    case missingArgument(String)
    case invalidArtifact(String)

    var errorDescription: String? {
        switch self {
        case .unknownCommand(let command):
            return "unknown command: \(command)"
        case .missingArgument(let message), .invalidArtifact(let message):
            return message
        }
    }
}

private struct FuzzSummary: Codable {
    let seed: UInt64
    let count: Int
    let artifactPath: String
    let reports: [EngineScenarioReport]
}

private struct EngineTraceEnvelope: Decodable {
    let engineTrace: EngineTrace?
}

private struct EngineTraceReplayCLIReport: Codable {
    let passed: Bool
    let stepCount: Int
    let invariantIDs: [String]
    let mismatches: [String]
    let finalSnapshot: EngineTraceReplaySnapshotSummary

    init(_ report: EngineTraceReplayReport) {
        self.passed = report.passed
        self.stepCount = report.stepCount
        self.invariantIDs = report.invariantIDs
        self.mismatches = report.mismatches
        self.finalSnapshot = EngineTraceReplaySnapshotSummary(report.finalSnapshot)
    }
}

private struct EngineTraceReplaySnapshotSummary: Codable {
    let conversation: String
    let transmit: String
    let receive: String
    let transport: String
    let lifecycle: EngineApplicationState
    let pttAudio: String
    let canTransmit: Bool
    let scheduledPlaybackCount: Int
    let activeTransmitID: String?

    init(_ snapshot: TurboEngineSnapshot) {
        self.conversation = Self.conversationName(snapshot.conversation)
        self.transmit = Self.transmitName(snapshot.transmit)
        self.receive = Self.receiveName(snapshot.receive)
        self.transport = Self.transportName(snapshot.transport)
        self.lifecycle = snapshot.lifecycle
        self.pttAudio = Self.pttAudioName(snapshot.pttAudio)
        self.canTransmit = {
            if case .available = snapshot.localTalkCapability { return true }
            return false
        }()
        self.scheduledPlaybackCount = snapshot.scheduledPlaybackCount
        self.activeTransmitID = snapshot.transmit.activeEpoch?.transmitID.rawValue
    }

    private static func conversationName(_ phase: EngineConversationPhase) -> String {
        switch phase {
        case .none: return "none"
        case .selected: return "selected"
        case .requesting: return "requesting"
        case .incomingBeep: return "incomingBeep"
        case .joining: return "joining"
        case .joined: return "joined"
        case .disconnecting: return "disconnecting"
        case .recovering: return "recovering"
        }
    }

    private static func transmitName(_ phase: EngineTransmitPhase) -> String {
        switch phase {
        case .idle: return "idle"
        case .beginning: return "beginning"
        case .active: return "active"
        case .stopping: return "stopping"
        case .failed: return "failed"
        }
    }

    private static func receiveName(_ phase: EngineReceivePhase) -> String {
        switch phase {
        case .idle: return "idle"
        case .prepared: return "prepared"
        case .awaitingPTTActivation: return "awaitingPTTActivation"
        case .receiving: return "receiving"
        case .draining: return "draining"
        case .failed: return "failed"
        }
    }

    private static func transportName(_ phase: EngineTransportPhase) -> String {
        switch phase {
        case .relayWebSocket: return "relayWebSocket"
        case .fastRelay: return "fastRelay"
        case .directQuic: return "directQuic"
        case .multipath: return "multipath"
        case .recovering: return "recovering"
        case .unavailable: return "unavailable"
        }
    }

    private static func pttAudioName(_ state: EnginePTTAudioActivationState) -> String {
        switch state {
        case .inactive: return "inactive"
        case .activating: return "activating"
        case .active: return "active"
        case .failed: return "failed"
        }
    }
}

private struct EngineFuzzCorpus: Codable {
    let schemaVersion: Int
    let cases: [EngineFuzzCorpusCase]
}

private struct EngineFuzzCorpusCase: Codable {
    let name: String
    let reason: String?
}

private struct FuzzCorpusSummary: Codable {
    let path: String
    let count: Int
    let reports: [EngineScenarioReport]
}

private struct EngineScenarioDifferentialReport: Codable {
    let name: String
    let inMemory: EngineScenarioReport
    let liveLocal: EngineScenarioReport

    var passed: Bool {
        inMemory.passed
            && liveLocal.passed
            && inMemory.scheduledPlaybackCount == liveLocal.scheduledPlaybackCount
            && inMemory.invariantIDs == liveLocal.invariantIDs
    }
}
