// ShellStream+Typed.swift is part of the swift-shell open source project.
//
// Copyright © 2025 Jared Bourgeois
//
// Licensed under Apache License v2.0 with Runtime Library Exception
//

import Foundation

public struct ShellStream: Sendable {
    public let onError: @Sendable (_ allOutput: ShellProcessOutput, _ stderrIncremental: Data) async throws -> Data?
    public let onOutput: @Sendable (_ allOutput: ShellProcessOutput, _ stdoutIncremental: Data) async throws -> Data?

    public init(
        onError: @escaping @Sendable (_ allOutput: ShellProcessOutput, _ stderrIncremental: Data) async throws -> Data?,
        onOutput: @escaping @Sendable (_ allOutput: ShellProcessOutput, _ stdoutIncremental: Data) async throws -> Data?
    ) {
        self.onError = onError
        self.onOutput = onOutput
    }
}

extension ShellStream {
    public enum StringStreamError: CustomNSError {
        public static let errorDomain = "ShellStream.StringStreamError"
        case decodeStringFromError(Int)
        case decodeStringFromOutput(Int)
        case encodeStringFromInput(String)
        public var errorCode: Int {
            switch self {
            case .decodeStringFromError: 0
            case .decodeStringFromOutput: 1
            case .encodeStringFromInput: 2
            }
        }
        public var errorUserInfo: [String: Any] {
            switch self {
            case .decodeStringFromError(let bytes): [
                NSLocalizedDescriptionKey: "Failed to decode String from stderr (\(bytes) bytes).",
            ]
            case .decodeStringFromOutput(let bytes): [
                NSLocalizedDescriptionKey: "Failed to decode String from stdout (\(bytes) bytes).",
            ]
            case .encodeStringFromInput(let string): [
                NSLocalizedDescriptionKey: "Failed to encode String (\(string)) to stdin.",
            ]
            }
        }
    }

    public static func stringStream(
        onError: @escaping @Sendable (_ allOutput: ShellProcessOutput, _ allStderr: String?, _ incrementalStderr: Data) async throws -> String?,
        onOutput: @escaping @Sendable (_ allOutput: ShellProcessOutput, _ allStdout: String?, _ incrementalStdout: Data) async throws -> String?,
        stringEncoding: String.Encoding = .utf8
    ) -> ShellStream {
        .init(
            onError: { shellProcessOutput, data in
                let errorDecoded = String(data: shellProcessOutput.stderr, encoding: stringEncoding)
                let input = try await onError(shellProcessOutput, errorDecoded, data)
                let inputEncoded = if let input {
                    if let inputData = input.data(using: stringEncoding) {
                        inputData
                    } else {
                        throw StringStreamError.encodeStringFromInput(input)
                    }
                } else {
                    nil as Data?
                }
                return inputEncoded
            },
            onOutput: { shellProcessOutput, data in
                let outputDecoded = String(data: shellProcessOutput.stdout, encoding: stringEncoding)
                let input = try await onOutput(shellProcessOutput, outputDecoded, data)
                let inputEncoded = if let input {
                    if let inputData = input.data(using: stringEncoding) {
                        inputData
                    } else {
                        throw StringStreamError.encodeStringFromInput(input)
                    }
                } else {
                    nil as Data?
                }
                return inputEncoded
            }
        )
    }
}
