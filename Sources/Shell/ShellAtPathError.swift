// Shell+AtPath+Error.swift is part of the swift-shell open source project.
//
// Copyright © 2025 Jared Bourgeois
//
// Licensed under Apache License v2.0 with Runtime Library Exception
//

import Foundation

public struct ShellAtPathError: ShellExecutionError {
    public enum Kind: Equatable, Sendable {
        case cancelled(ShellTermination.Status)
        case run
        case streamInputWriteErr
        case streamInputWriteOut
        case streamOnErr
        case streamOnOut
        case termination(ShellTermination.Status)
        case timeout
    }
    public let kind: Kind
    public let status: ShellTermination.Status
    public let userInfo: [String: String]

    var termination: ShellTermination {
        .init(reason: .uncaughtSignal, status: status)
    }

    public init(
        kind: Kind,
        userInfo: [String: String]
    ) {
        self.kind = kind
        self.status = switch kind {
        case .cancelled(let status): status
        case .run: 1002
        case .streamInputWriteErr: 1003
        case .streamInputWriteOut: 1004
        case .streamOnErr: 1005
        case .streamOnOut: 1006
        case .termination(let status): status
        case .timeout: 1007
        }
        self.userInfo = userInfo
    }

    public static func cancelled(
        command: String,
        location: ShellAtPathProcess.CancellationLocation,
        status: ShellTermination.Status
    ) -> Self {
        .init(
            kind: .cancelled(status),
            userInfo: [
                Self.commandKey: maskCommand(command),
                NSLocalizedDescriptionKey: "Shell.atPath process was cancelled from \(location.rawValue).",
            ]
        )
    }
    public static func run(
        command: String,
        error: some Swift.Error
    ) -> Self {
        .init(
            kind: .run,
            userInfo: (error as NSError)
                .userInfo.mapValues { String(describing: $0) }
                .merging([
                    Self.commandKey: maskCommand(command),
                    NSLocalizedDescriptionKey: "Shell.atPath encountered an error when starting the process.",
                    NSUnderlyingErrorKey: errorDescription(error),
                ]) { $1 }

        )
    }
    public static func streamInputWriteErr(
        command: String,
        error: some Swift.Error,
        input: Data,
        inputStringEncoding: String.Encoding
    ) -> Self {
        .init(
            kind: .streamInputWriteErr,
            userInfo: (error as NSError)
                .userInfo.mapValues { String(describing: $0) }
                .merging([
                    Self.commandKey: maskCommand(command),
                    NSLocalizedDescriptionKey: "Shell.atPath stream encountered an error when writing input from stderr: \(String(data: input, encoding: inputStringEncoding) ?? "\(input.count) bytes")",
                    NSUnderlyingErrorKey: errorDescription(error),
                ]) { $1 }

        )
    }
    public static func streamInputWriteOut(
        command: String,
        error: some Swift.Error,
        input: Data,
        inputStringEncoding: String.Encoding
    ) -> Self {
        .init(
            kind: .streamInputWriteOut,
            userInfo: (error as NSError)
                .userInfo.mapValues { String(describing: $0) }
                .merging([
                    Self.commandKey: maskCommand(command),
                    NSLocalizedDescriptionKey: "Shell.atPath stream encountered an error when writing input from stdout: \(String(data: input, encoding: inputStringEncoding) ?? "\(input.count) bytes")",
                    NSUnderlyingErrorKey: errorDescription(error),
                ]) { $1 }
        )
    }
    public static func streamOnErr(
        command: String,
        error: some Swift.Error
    ) -> Self {
        .init(
            kind: .streamOnErr,
            userInfo: (error as NSError)
                .userInfo.mapValues { String(describing: $0) }
                .merging([
                    Self.commandKey: maskCommand(command),
                    NSLocalizedDescriptionKey: "Shell.atPath stream threw an error on stderr.",
                    NSUnderlyingErrorKey: errorDescription(error),
                ]) { $1 }
        )
    }
    public static func streamOnOut(
        command: String,
        error: some Swift.Error
    ) -> Self {
        .init(
            kind: .streamOnOut,
            userInfo: (error as NSError)
                .userInfo.mapValues { String(describing: $0) }
                .merging([
                    Self.commandKey: maskCommand(command),
                    NSLocalizedDescriptionKey: "Shell.atPath stream threw an error on stdout.",
                    NSUnderlyingErrorKey: errorDescription(error),
                ]) { $1 }
        )
    }
    public static func termination(
        command: String,
        status: ShellTermination.Status
    ) -> Self {
        .init(
            kind: .termination(status),
            userInfo: [
                NSLocalizedDescriptionKey: "Shell.atPath terminated with error status (\(status)).",
                "status": "\(status)",
            ]
        )
    }
    public static func timeout(
        command: String,
        timeoutInterval: TimeInterval
    ) -> Self {
        .init(
            kind: .timeout,
            userInfo: [
                NSLocalizedDescriptionKey: "Shell.atPath timed out after interval (\(timeoutInterval)).",
            ]
        )
    }
}

extension ShellAtPathError: CustomNSError {
    public static let errorDomain = "ShellAtPathError"
    public var errorCode: Int { Int(status) }
    public var errorUserInfo: [String: Any] { userInfo as [String: Any] }
}

extension ShellAtPathError {
    private static var commandKey: String { "Command" }
    private static func errorDescription(_ error: some Swift.Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }
    private static func maskCommand(_ command: String) -> String {
        let x = 8
        guard command.count >= 8 else { return command }
        let index = command.index(command.startIndex, offsetBy: x)
        let prefix = command[..<index]
        let asterisks = String(repeating: "*", count: command.count - x)
        return String(prefix) + asterisks
    }
}
