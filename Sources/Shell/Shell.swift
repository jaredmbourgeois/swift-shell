// Shell.swift is part of the swift-shell open source project.
//
// Copyright © 2025 Jared Bourgeois
//
// Licensed under Apache License v2.0 with Runtime Library Exception
//

import Foundation

public protocol ShellExecutionError: Swift.Error, Equatable, Sendable {}

public typealias ShellExecute<Error: ShellExecutionError> = @Sendable (
    _ command: ShellCommand,
    _ dryRun: Bool,
    _ estimatedOutputSize: Int?,
    _ estimatedErrorSize: Int?,
    _ statusesForResult: ShellTermination.StatusesForResult,
    _ stream: ShellStream?,
    _ timeout: TimeInterval?
) async -> ShellResult<Error>

public struct Shell<Error: ShellExecutionError>: Sendable {
    private let _execute: ShellExecute<Error>

    /// Custom `ShellExecute` implementation, eg mocking.
    public init(execute: @escaping ShellExecute<Error>) {
        _execute = execute
    }

    /// Executes `command`. Provide estimated stdout/err sizes. Read stdout/err and provide input with `stream`.
    public func execute(
        _ command: ShellCommand,
        dryRun: Bool = false,
        estimatedOutputSize: Int? = nil,
        estimatedErrorSize: Int? = nil,
        statusesForResult: ShellTermination.StatusesForResult = .init(),
        stream: ShellStream? = nil,
        timeout: TimeInterval? = nil
    ) async -> ShellResult<Error> {
        await _execute(command, dryRun, estimatedOutputSize, estimatedErrorSize, statusesForResult, stream, timeout)
    }
}

public typealias ShellCommand = String

public struct ShellResult<Error: Swift.Error>: Sendable {
    public let error: Error?
    public let processOutput: ShellProcessOutput
    public let termination: ShellTermination

    public init(
        error: Error?,
        processOutput: ShellProcessOutput,
        termination: ShellTermination
    ) {
        self.error = error
        self.processOutput = processOutput
        self.termination = termination
    }

    public func get() throws(Error) -> ShellProcessOutput {
        guard let error else {
            return processOutput
        }
        throw error
    }

    public static func success(
        stderr: Data = Data(),
        stdout: Data = Data()
    ) -> Self {
        .init(
            error: nil,
            processOutput: .init(
                stderr: stderr,
                stdout: stdout
            ),
            termination: .init(
                reason: .exit,
                status: .zero
            )
        )
    }
    public static func success(
        stderr: String = "",
        stdout: String,
        stringEncoding: String.Encoding = .utf8
    ) -> Self? {
        guard let stderrData = stderr.data(using: stringEncoding),
              let stdoutData = stdout.data(using: stringEncoding) else {
            return nil
        }
        return .init(
            error: nil,
            processOutput: .init(
                stderr: stderrData,
                stdout: stdoutData
            ),
            termination: .init(
                reason: .exit,
                status: 0
            )
        )
    }
}

public struct ShellTermination: Sendable {
    public enum Reason: String, Sendable {
        case exit
        case uncaughtSignal
        case unknown
        public init?(rawValue: String) {
            self = switch rawValue {
            case Reason.exit.rawValue: .exit
            case Reason.uncaughtSignal.rawValue: .uncaughtSignal
            default: .unknown
            }
        }
        public init(_ processTerminationReason: Process.TerminationReason) {
            self = switch processTerminationReason {
            case Process.TerminationReason.exit: .exit
            case Process.TerminationReason.uncaughtSignal: .uncaughtSignal
            @unknown default: .unknown
            }
        }
    }

    public typealias Status = Int32

    public let reason: Reason
    public let status: Status

    public init(
        reason: Reason,
        status: Status
    ) {
        self.reason = reason
        self.status = status
    }
}

extension ShellTermination.Status {
    public static var defaultCancellationStatus: Self { 15 }
    public static var defaultSuccessStatus: Self { 0 }
}

extension ShellTermination {
    public struct StatusesForResult: Sendable {
        public let cancellations: [Status]
        public let successes: [Status]
        public init(
            cancellations: [Status] = [.defaultCancellationStatus],
            successes: [Status] = [.defaultSuccessStatus]
        ) {
            self.cancellations = cancellations
            self.successes = successes
        }
    }
}

func _forceCastError<In: Error, Out: Error>(_ input: In, function: String = #function, line: Int = #line) -> Out {
    guard let input = input as? Out else {
        fatalError("Shell force cast from \(In.self) to \(Out.self) at \(function) L\(line) failed.")
    }
    return input
}
