import Foundation
import Testing
import PushToTalk
import AVFAudio
import UIKit
import UserNotifications
import Intents
import CryptoKit
import TurboEngine

@testable import BeepBeep

enum BackendContractManifestError: Error {
    case missing(String)
}

func backendContractManifest() throws -> [String: Any] {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = repoRoot.appendingPathComponent("shared/contracts/backend_channel_contract_manifest.json")
    let data = try Data(contentsOf: url)
    guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw BackendContractManifestError.missing("manifest root object")
    }
    return manifest
}

func backendContractVariants(_ manifest: [String: Any], _ name: String) throws -> Set<String> {
    let contracts = try backendContractDictionary(manifest["contracts"], path: "contracts")
    let contract = try backendContractDictionary(contracts[name], path: "contracts.\(name)")
    let variants = try backendContractArray(contract["variants"], path: "contracts.\(name).variants")
    return Set(try variants.map { try backendContractString($0, path: "contracts.\(name).variants[]") })
}

func backendContractExamples(_ manifest: [String: Any], _ name: String) throws -> [[String: Any]] {
    let responseExamples = try backendContractDictionary(manifest["responseExamples"], path: "responseExamples")
    let examples = try backendContractArray(responseExamples[name], path: "responseExamples.\(name)")
    return try examples.map { try backendContractDictionary($0, path: "responseExamples.\(name)[]") }
}

func backendContractInvalidExamples(_ manifest: [String: Any]) throws -> [[String: Any]] {
    let examples = try backendContractArray(manifest["invalidExamples"], path: "invalidExamples")
    return try examples.map { try backendContractDictionary($0, path: "invalidExamples[]") }
}

func backendContractPayloadData(_ payload: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
}

func backendContractDictionary(_ value: Any?, path: String) throws -> [String: Any] {
    guard let dictionary = value as? [String: Any] else {
        throw BackendContractManifestError.missing(path)
    }
    return dictionary
}

func backendContractArray(_ value: Any?, path: String) throws -> [Any] {
    guard let array = value as? [Any] else {
        throw BackendContractManifestError.missing(path)
    }
    return array
}

func backendContractString(_ value: Any?, path: String) throws -> String {
    guard let string = value as? String else {
        throw BackendContractManifestError.missing(path)
    }
    return string
}


