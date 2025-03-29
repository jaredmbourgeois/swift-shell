// ShellStream+Typed.swift is part of the swift-shell open source project.
//
// Copyright © 2025 Jared Bourgeois
//
// Licensed under Apache License v2.0 with Runtime Library Exception
//

import Foundation

extension ShellStream {
    public static func typedStream<Output: Sendable & Decodable, Error: Sendable & Decodable, Input: Sendable & Encodable>(
        encodeInput: @escaping @Sendable (Input) throws -> Data,
        onOutput: @escaping @Sendable (ShellProcessOutput.Typed<Output, Error>, _ incrementalData: Data) async throws -> Input?,
        onOutputDecode: @escaping @Sendable (Data) throws -> Output,
        onError: @escaping @Sendable (ShellProcessOutput.Typed<Output, Error>, _ incrementalData: Data) async throws -> Input?,
        onErrorDecode: @escaping @Sendable (Data) throws -> Error
    ) -> ShellStream {
        .init(
            onOutput: { shellProcessOutput, data in
                guard
                    let input = try? await onOutput(
                        ShellProcessOutput.Typed<Output, Error>(
                            shellProcessOutput: shellProcessOutput,
                            stdoutDecode: { try onOutputDecode($0) },
                            stderrDecode: { try onErrorDecode($0) }
                        ),
                        data
                    ),
                    let inputData = try? encodeInput(input) else {
                    return nil
                }
                return inputData
            },
            onError: { shellProcessOutput, data in
                guard
                    let input = try? await onError(
                        ShellProcessOutput.Typed<Output, Error>(
                            shellProcessOutput: shellProcessOutput,
                            stdoutDecode: { try onOutputDecode($0) },
                            stderrDecode: { try onErrorDecode($0) }
                        ),
                        data
                    ),
                    let inputData = try? encodeInput(input) else {
                    return nil
                }
                return inputData
            }
        )
    }

    public static func jsonStream<Output: Sendable & Decodable, Error: Sendable & Decodable, Input: Sendable & Encodable>(
        inputEncoder: JSONEncoder = JSONEncoder(),
        outputDecoder: JSONDecoder = JSONDecoder(),
        errorDecoder: JSONDecoder = JSONDecoder(),
        onOutput: @escaping @Sendable (ShellProcessOutput.Typed<Output, Error>, _ incrementalData: Data) async throws -> Input?,
        onError: @escaping @Sendable (ShellProcessOutput.Typed<Output, Error>, _ incrementalData: Data) async throws -> Input?
    ) -> ShellStream {
        .typedStream(
            encodeInput: { try inputEncoder.encode($0) },
            onOutput: onOutput,
            onOutputDecode: { try outputDecoder.decode(Output.self, from: $0) },
            onError: onError,
            onErrorDecode: { try errorDecoder.decode(Error.self, from: $0) }
        )
    }

    public enum StringStreamError: Swift.Error {
        case decodeError(Int)
        case decodeOutput(Int)
        case encode
    }

    public static func stringStream(
        encoding: String.Encoding = .utf8,
        onOutput: @escaping @Sendable (ShellProcessOutput.Typed<String, String>, _ incrementalData: Data) async throws -> String?,
        onError: @escaping @Sendable (ShellProcessOutput.Typed<String, String>, _ incrementalData: Data) async throws -> String?
    ) -> ShellStream {
        .typedStream(
            encodeInput: {
                guard let data = $0.data(using: encoding) else {
                    throw StringStreamError.encode
                }
                return data
            },
            onOutput: onOutput,
            onOutputDecode: {
                guard let data = String(data: $0, encoding: encoding) else {
                    throw StringStreamError.decodeOutput($0.count)
                }
                return data
            },
            onError: onError,
            onErrorDecode: {
                guard let data = String(data: $0, encoding: encoding) else {
                    throw StringStreamError.decodeError($0.count)
                }
                return data
            }
        )
    }
}
