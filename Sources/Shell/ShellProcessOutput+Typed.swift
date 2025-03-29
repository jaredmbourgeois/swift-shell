// ShellProcessOutput+Typed.swift is part of the swift-shell open source project.
//
// Copyright © 2025 Jared Bourgeois
//
// Licensed under Apache License v2.0 with Runtime Library Exception
//

import Foundation

extension ShellProcessOutput {
    public struct Typed<Output: Sendable & Decodable, Error: Sendable & Decodable>: Sendable {
        private let shellProcessOutput: ShellProcessOutput
        public var stdout: Data { shellProcessOutput.stdout }
        public let stdoutTyped: @Sendable () throws -> Output
        public var stderr: Data { shellProcessOutput.stderr }
        public let stderrTyped: @Sendable () throws -> Error

        public init(
            shellProcessOutput: ShellProcessOutput,
            stdoutDecode: @escaping @Sendable (Data) throws -> Output,
            stderrDecode: @escaping @Sendable (Data) throws -> Error
        ) {
            self.shellProcessOutput = shellProcessOutput
            let stdoutTyped: @Sendable () throws -> Output = { try stdoutDecode(shellProcessOutput.stdout) }
            self.stdoutTyped = stdoutTyped
            let stderrTyped: @Sendable () throws -> Error = { try stderrDecode(shellProcessOutput.stderr) }
            self.stderrTyped = stderrTyped
        }
    }

    public func typedProcessOutput<Output: Sendable & Decodable, Error: Sendable & Decodable>(
        stdoutDecode: @escaping @Sendable (Data) throws -> Output,
        stderrDecode: @escaping @Sendable (Data) throws -> Error
    ) -> ShellProcessOutput.Typed<Output, Error> {
        .init(
            shellProcessOutput: self,
            stdoutDecode: stdoutDecode,
            stderrDecode: stderrDecode
        )
    }

    public func jsonProcessOutput<Output: Sendable & Decodable, Error: Sendable & Decodable>(
        stdoutDecoder: JSONDecoder = JSONDecoder(),
        stderrDecoder: JSONDecoder = JSONDecoder()
    ) -> ShellProcessOutput.Typed<Output, Error> {
        .init(
            shellProcessOutput: self,
            stdoutDecode: { try stdoutDecoder.decode(Output.self, from: $0) },
            stderrDecode: { try stderrDecoder.decode(Error.self, from: $0) }
        )
    }

    public enum StringProcessOutputError: Swift.Error {
        case decodeError(Int)
        case decodeOutput(Int)
    }

    public func stringProcessOutput(encoding: String.Encoding = .utf8) -> ShellProcessOutput.Typed<String, String> {
        .init(
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
