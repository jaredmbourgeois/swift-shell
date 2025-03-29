// ShellProcessOutput+Typed.swift is part of the swift-shell open source project.
//
// Copyright © 2025 Jared Bourgeois
//
// Licensed under Apache License v2.0 with Runtime Library Exception
//

import Foundation

extension ShellProcessOutput {
    public struct Typed<Output: Sendable & Decodable, Error: Sendable & Decodable>: Sendable {
        public let shellProcessOutput: ShellProcessOutput
        public let stdoutTyped: Output
        public let stderrTyped: Error

        public init(
            shellProcessOutput: ShellProcessOutput,
            stdoutDecode: @escaping @Sendable (Data) throws -> Output,
            stderrDecode: @escaping @Sendable (Data) throws -> Error
        ) throws {
            self.shellProcessOutput = shellProcessOutput
            self.stdoutTyped = try stdoutDecode(shellProcessOutput.stdout)
            self.stderrTyped = try stderrDecode(shellProcessOutput.stderr)
        }
    }

    public func typedProcessOutput<Output: Sendable & Decodable, Error: Sendable & Decodable>(
        stdoutDecode: @escaping @Sendable (Data) throws -> Output,
        stderrDecode: @escaping @Sendable (Data) throws -> Error
    ) throws -> ShellProcessOutput.Typed<Output, Error> {
        try .init(
            shellProcessOutput: self,
            stdoutDecode: stdoutDecode,
            stderrDecode: stderrDecode
        )
    }

    public func jsonProcessOutput<Output: Sendable & Decodable, Error: Sendable & Decodable>(
        stdoutDecoder: JSONDecoder = JSONDecoder(),
        stderrDecoder: JSONDecoder = JSONDecoder()
    ) throws -> ShellProcessOutput.Typed<Output, Error> {
        try .init(
            shellProcessOutput: self,
            stdoutDecode: { try stdoutDecoder.decode(Output.self, from: $0) },
            stderrDecode: { try stderrDecoder.decode(Error.self, from: $0) }
        )
    }

    public enum StringProcessOutputError: Swift.Error {
        case decodeError(Int)
        case decodeOutput(Int)
    }

    public func stringProcessOutput(encoding: String.Encoding = .utf8) throws -> ShellProcessOutput.Typed<String, String> {
        try .init(
            shellProcessOutput: self,
            stdoutDecode: {
                guard let data = String(data: $0, encoding: encoding) else {
                    throw StringProcessOutputError.decodeOutput($0.count)
                }
                return data
            },
            stderrDecode: {
                guard let data = String(data: $0, encoding: encoding) else {
                    throw StringProcessOutputError.decodeError($0.count)
                }
                return data
            }
        )
    }
}
