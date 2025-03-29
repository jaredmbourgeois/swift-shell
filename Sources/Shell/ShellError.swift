// ShellError.swift is part of the swift-shell open source project.
//
// Copyright © 2025 Jared Bourgeois
//
// Licensed under Apache License v2.0 with Runtime Library Exception
//

import Foundation

public struct ShellError: Error, Sendable, Equatable {
    public enum ErrorType: String, Sendable {
        case cancelled
        case input
        case run
        case terminationError
        case timeout
        case union
    }

    public let type: Self.ErrorType
    public let userInfo: [String: String]

    func union(_ shellError: ShellError) -> ShellError {
        .init(
            type: type == shellError.type ? type : .union,
            userInfo: {
                switch self.type {
                case .union:
                    [
                        "\(shellError.type.rawValue)-\(userInfo.keys.count + 1)": String(describing: shellError.userInfo)
                    ]
                default:
                    [
                        "\(type.rawValue)-1": String(describing: userInfo),
                        "\(shellError.type.rawValue)-2": String(describing: shellError.userInfo)
                    ]
                }
            }()
        )
    }

    public static func cancelled(
        description: String
    ) -> ShellError {
        .init(
            type: .cancelled,
            userInfo: [
                NSLocalizedDescriptionKey: "Task for \(description) was cancelled.",
            ]
        )
    }

    public static func input(
        error: some Swift.Error,
        input: Data,
        inputStringEncoding: String.Encoding
    ) -> ShellError {
        let nsError = error as NSError
        return .init(
            type: .input,
            userInfo: nsError.userInfo.mapValues { String(describing: $0) }.merging([
                NSUnderlyingErrorKey: "\(nsError.domain) \(nsError.code)",
                NSLocalizedDescriptionKey: "Input provided (\(String(data: input, encoding: inputStringEncoding) ?? "unknown stdin (\(input.count) bytes)") threw an error.",
            ]) { $1 }
        )
    }

    public static func run(
        error: some Swift.Error
    ) -> ShellError {
        let nsError = error as NSError
        return .init(
            type: .run,
            userInfo: nsError.userInfo.mapValues { String(describing: $0) }.merging([
                NSUnderlyingErrorKey: "\(nsError.domain) \(nsError.code)",
                NSLocalizedDescriptionKey: "Process run threw an error: \(nsError.localizedDescription).",
            ]) { $1 }
        )
    }

    public static func terminationError(termination: ShellTermination) -> ShellError {
        .init(
            type: .terminationError,
            userInfo: [
                NSLocalizedDescriptionKey: "Shell command terminated with error status: \(termination.status), reason: \(termination.reason.rawValue).",
            ]
        )
    }
    public static func timeout(
        timeoutInterval: TimeInterval
    ) -> ShellError {
        .init(
            type: .timeout,
            userInfo: [
                NSLocalizedDescriptionKey: "Shell timed out after interval (\(timeoutInterval)).",
            ]
        )
    }
}

extension ShellError: CustomNSError {
    public static let errorDomain: String = "ShellError"
    public var errorCode: Int {
        switch self.type {
        case .cancelled: 0
        case .input: 1
        case .run: 2
        case .terminationError: 3
        case .timeout: 4
        case .union: 5
        }
    }
    public var errorUserInfo: [String: Any] { userInfo as [String: Any] }
}
