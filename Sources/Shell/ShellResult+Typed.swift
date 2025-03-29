// ShellResult+Typed.swift is part of the swift-shell open source project.
//
// Copyright © 2025 Jared Bourgeois
//
// Licensed under Apache License v2.0 with Runtime Library Exception
//

import Foundation

extension ShellResult {
    public struct Typed<Output: Sendable & Decodable, Error: Sendable & Decodable>: Sendable {
        public let output: Output
        public let error: Error
        public var isSuccess: Bool { terminationStatus == .zero }
        public let terminationReason: String
        public let terminationStatus: Int32
    }

    public func typedResult<Output: Sendable & Decodable, Error: Sendable & Decodable>(
        decodeOutput: (Data) throws -> Output,
        decodeError: (Data) throws -> Error
    ) throws -> Typed<Output, Error> {
        .init(
            output: try decodeOutput(output),
            error: try decodeError(error),
            terminationReason: terminationReason,
            terminationStatus: terminationStatus
        )
    }

    public func jsonResult<Output: Sendable & Decodable, Error: Sendable & Decodable>(
        outputDecoder: JSONDecoder = JSONDecoder(),
        errorDecoder: JSONDecoder = JSONDecoder()
    ) throws -> Typed<Output, Error> {
        try typedResult(
            decodeOutput: { try outputDecoder.decode(Output.self, from: $0) },
            decodeError: { try errorDecoder.decode(Error.self, from: $0) }
        )
    }

    public enum StringResultError: Swift.Error {
        case decodeError(Int)
        case decodeOutput(Int)
    }

    public func stringResult(encoding: String.Encoding = .utf8) throws -> Typed<String, String> {
        try typedResult(
            decodeOutput: {
                guard let data = String(data: $0, encoding: encoding) else {
                    throw StringResultError.decodeOutput($0.count)
                }
                return data
            },
            decodeError: {
                guard let data = String(data: $0, encoding: encoding) else {
                    throw StringResultError.decodeError($0.count)
                }
                return data
            }
        )
    }
}
