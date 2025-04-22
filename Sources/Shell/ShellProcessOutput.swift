// ShellProcessOutput.swift is part of the swift-shell open source project.
//
// Copyright © 2025 Jared Bourgeois
//
// Licensed under Apache License v2.0 with Runtime Library Exception
//

import Foundation

public struct ShellProcessOutput: Sendable {
    public let stderr: Data
    public let stdout: Data

    public init(
        stderr: Data,
        stdout: Data
    ) {
        self.stderr = stderr
        self.stdout = stdout
    }
}

extension ShellProcessOutput {
    public struct Decoded<Output: Sendable & Decodable, Error: Sendable & Decodable>: Sendable {
        public let shellProcessOutput: ShellProcessOutput
        public let stderrTyped: Error
        public let stdoutTyped: Output

        public init(
            shellProcessOutput: ShellProcessOutput,
            stderrDecode: @escaping @Sendable (Data) throws -> Error,
            stdoutDecode: @escaping @Sendable (Data) throws -> Output
        ) throws {
            self.shellProcessOutput = shellProcessOutput
            self.stdoutTyped = try stdoutDecode(shellProcessOutput.stdout)
            self.stderrTyped = try stderrDecode(shellProcessOutput.stderr)
        }
    }

    public func decode<Output: Sendable & Decodable, Error: Sendable & Decodable>(
        stderrDecode: @escaping @Sendable (Data) throws -> Error,
        stdoutDecode: @escaping @Sendable (Data) throws -> Output
    ) throws -> ShellProcessOutput.Decoded<Output, Error> {
        try .init(
            shellProcessOutput: self,
            stderrDecode: stderrDecode,
            stdoutDecode: stdoutDecode
        )
    }

    public func decodeJSON<Output: Sendable & Decodable, Error: Sendable & Decodable>(
        stderrDecoder: JSONDecoder,
        stdoutDecoder: JSONDecoder
    ) throws -> ShellProcessOutput.Decoded<Output, Error> {
        try .init(
            shellProcessOutput: self,
            stderrDecode: { try stderrDecoder.decode(Error.self, from: $0) },
            stdoutDecode: { try stdoutDecoder.decode(Output.self, from: $0) }
        )
    }

    public func decodeJSON<Output: Sendable & Decodable, Error: Sendable & Decodable>(jsonDecoder: JSONDecoder = JSONDecoder()) throws -> ShellProcessOutput.Decoded<Output, Error> {
        try decodeJSON(stderrDecoder: jsonDecoder, stdoutDecoder: jsonDecoder)
    }

    public func decodeString(encoding: String.Encoding = .utf8) throws -> ShellProcessOutput.Decoded<String, String> {
        try .init(
            shellProcessOutput: self,
            stderrDecode: {
                guard let string = String(data: $0, encoding: encoding) else {
                    throw DecodeStringError.decodeStringFromError($0.count)
                }
                return string
            },
            stdoutDecode: {
                guard let string = String(data: $0, encoding: encoding) else {
                    throw DecodeStringError.decodeStringFromOutput($0.count)
                }
                return string
            }
        )
    }

    public func decodeStringLines(encoding: String.Encoding = .utf8, lineSeparator: String = "\n") throws -> ShellProcessOutput.Decoded<[String], [String]> {
        try .init(
            shellProcessOutput: self,
            stderrDecode: {
                guard let string = String(data: $0, encoding: encoding) else {
                    throw DecodeStringError.decodeStringFromError($0.count)
                }
                return string.split(separator: lineSeparator).map { String($0) }
            },
            stdoutDecode: {
                guard let string = String(data: $0, encoding: encoding) else {
                    throw DecodeStringError.decodeStringFromOutput($0.count)
                }
                return string.split(separator: lineSeparator).map { String($0) }
            }
        )
    }

    public enum DecodeStringError: CustomNSError {
        public static let errorDomain = "ShellProcessOutput.DecodeStringError"

        case decodeStringFromError(Int)
        case decodeStringFromOutput(Int)

        public var errorCode: Int {
            switch self {
            case .decodeStringFromError: 0
            case .decodeStringFromOutput: 1
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
            }
        }
    }
}
