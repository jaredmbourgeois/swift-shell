// Shell.swift is part of the swift-shell open source project.
//
// Copyright © 2025 Jared Bourgeois
//
// Licensed under Apache License v2.0 with Runtime Library Exception
//

import Foundation

public struct Shell: Sendable {
    public typealias Execute = @Sendable (
        _ command: ShellCommand,
        _ dryRun: Bool,
        _ estimatedOutputSize: Int?,
        _ estimatedErrorSize: Int?,
        _ exitStatus: @escaping @Sendable (ShellTermination.Status) -> ShellExitStatus,
        _ stream: ShellStream?,
        _ timeout: TimeInterval?
    ) async -> ShellResult

    private let _execute: Execute

    /// Custom `Shell.Execute` implementation, eg mocking.
    public init(execute: @escaping Execute) {
        _execute = execute
    }

    /// Executes `command`. Provide estimated stdout/err sizes. Read stdout/err and provide input with `stream`.
    public func execute(
        _ command: ShellCommand,
        dryRun: Bool = false,
        estimatedOutputSize: Int? = nil,
        estimatedErrorSize: Int? = nil,
        exitStatus: @escaping @Sendable (ShellTermination.Status) -> ShellExitStatus = {
            switch $0 {
            case 0: .success
            case ShellTermination.statusForCancellationDefault: .cancelled
            default: .failure
            }
        },
        stream: ShellStream? = nil,
        timeout: TimeInterval? = nil
    ) async -> ShellResult {
        await _execute(command, dryRun, estimatedOutputSize, estimatedErrorSize, exitStatus, stream, timeout)
    }
}

public typealias ShellCommand = String

public enum ShellExitStatus: Sendable {
    case cancelled
    case failure
    case success
}

public struct ShellObserver: Sendable {
    public let onError: (@Sendable (String, ShellProcessOutput, Data) async -> Void)?
    public let onOutput: (@Sendable (String, ShellProcessOutput, Data) async -> Void)?
    public let onResult: (@Sendable (String, ShellResult) async -> Void)?

    public init(
        onError: (@Sendable (String, ShellProcessOutput, Data) async -> Void)? = nil,
        onOutput: (@Sendable (String, ShellProcessOutput, Data) async -> Void)? = nil,
        onResult: (@Sendable (String, ShellResult) async -> Void)? = nil
    ) {
        self.onError = onError
        self.onOutput = onOutput
        self.onResult = onResult
    }
}

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

public struct ShellResult: Sendable {
    public let error: ShellError?
    public let processOutput: ShellProcessOutput
    public let termination: ShellTermination

    public init(
        error: ShellError?,
        processOutput: ShellProcessOutput,
        termination: ShellTermination
    ) {
        self.error = error
        self.processOutput = processOutput
        self.termination = termination
    }

    public func get() throws(ShellError) -> ShellProcessOutput {
        guard let error else {
            return processOutput
        }
        throw error
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
    public static let statusForCancellationDefault: Int32 = 15

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

public actor ShellSerialize {
    private var running = false
    private var queue: Array<CheckedContinuation<Void, Never>>

    public init(estimatedCapacity: Int = 16) {
        queue = Array<CheckedContinuation<Void, Never>>()
        queue.reserveCapacity(estimatedCapacity)
    }

    public func callAsFunction<T: Sendable, E: Error>(_ operation: @Sendable () async throws(E) -> T) async throws(E) -> T {
        guard !running else {
            await withCheckedContinuation { continuation in
                queue.append(continuation)
            }
            return try await performOperationAndResumeNextInQueue(operation).get()
        }
        return try await performOperationAndResumeNextInQueue(operation).get()
    }

    public func callAsFunction<T: Sendable>(_ operation: @Sendable () async -> T) async -> T {
        let throwingOperation: @Sendable () async throws(NSError) -> T = { await operation() }
        return try! await callAsFunction(throwingOperation)
    }

    private func performOperationAndResumeNextInQueue<T: Sendable, E: Error>(
        _ operation: @Sendable () async throws(E) -> T
    ) async -> Result<T, E> {
        running = true
        defer {
            if !queue.isEmpty {
                queue.removeFirst().resume()
            } else {
                running = false
            }
        }
        let result: Result<T, E> = await {
            do {
                return .success(try await operation())
            } catch {
                return .failure(_forceCastError(error))
            }
        }()
        return result
    }
}

public struct ShellStream: Sendable {
    public let onOutput: @Sendable (ShellProcessOutput, Data) async -> Data?
    public let onError: @Sendable (ShellProcessOutput, Data) async -> Data?

    public init(
        onOutput: @escaping @Sendable (ShellProcessOutput, Data) async -> Data?,
        onError: @escaping @Sendable (ShellProcessOutput, Data) async -> Data?
    ) {
        self.onOutput = onOutput
        self.onError = onError
    }
}

func _forceCastError<In: Error, Out: Error>(_ input: In, function: String = #function, line: Int = #line) -> Out {
    guard let input = input as? Out else {
        fatalError("Shell force cast from \(In.self) to \(Out.self) at \(function) L\(line) failed.")
    }
    return input
}
