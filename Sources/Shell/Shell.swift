// Shell.swift is part of the swift-shell open source project.
//
// Copyright © 2025 Jared Bourgeois
//
// Licensed under Apache License v2.0 with Runtime Library Exception
//

import Foundation

public struct Shell: Sendable {
    public typealias Execute = @Sendable (
        _ command: String,
        _ dryRun: Bool,
        _ estimatedOutputSize: Int?,
        _ estimatedErrorSize: Int?,
        _ stream: ShellStream?,
        _ timeout: TimeInterval?
    ) async throws -> ShellResult

    private let _execute: Execute

    /// Custom `Shell.Execute` implementation, eg mocking.
    public init(execute: @escaping Execute) {
        _execute = execute
    }

    /// Executes `command`. Provide estimated stdout/err sizes. Read stdout/err and provide input with `stream`.
    public func execute(
        _ command: String,
        dryRun: Bool = false,
        estimatedOutputSize: Int? = nil,
        estimatedErrorSize: Int? = nil,
        stream: ShellStream? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> ShellResult {
        try await _execute(command, dryRun, estimatedOutputSize, estimatedErrorSize, stream, timeout)
    }
}

extension Shell {
    /// Defaults to `/bin/bash`.
    public static func atPath(
        _ shellPath: String = "/bin/bash",
        defaultEstimatedErrorCapacity: Int = 4096,
        defaultEstimatedOutputCapacity: Int = 16_384
    ) -> Shell {
        .init { command, dryRun, estimatedOutputSize, estimatedErrorSize, stream, timeout in
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: shellPath)

                let command = dryRun ? "echo \"\(command)\"" : command
                process.arguments = ["-c", command]

                let stderrPipe = Pipe()
                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                process.standardError = stderrPipe
                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe

                let processOutput = ShellProcessOutput(
                    errCapacity: estimatedErrorSize ?? defaultEstimatedErrorCapacity,
                    outCapacity: estimatedOutputSize ?? defaultEstimatedOutputCapacity
                )
                let serialize = ShellSerialize()
                let executionState = _ShellExecutionState()

                @Sendable func terminateWithResult(_ result: Result<ShellResult, any Error>) {
                    guard executionState.shouldTerminateWithResult() else {
                        return
                    }
                    Task {
                        if process.isRunning {
                            process.terminate()
                        }
                        executionState.cancelTasks()
                        try? stdinPipe.fileHandleForWriting.close()
                        try? stderrPipe.fileHandleForReading.close()
                        try? stdoutPipe.fileHandleForReading.close()
                        stderrPipe.fileHandleForReading.readabilityHandler = nil
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        continuation.resume(with: result)
                    }
                }

                @Sendable func writeInput(_ data: Data) {
                    guard data.count > 0 else { return }
                    do {
                        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
                    } catch {
                        terminateWithResult(.failure(ShellError.input(error, "\(String(data: data, encoding: .utf8) ?? "\(data.count) bits")")))
                    }
                }

                stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                    let availableData = handle.availableData
                    guard availableData.count > 0 else { return }
                    executionState.canceling {
                        do {
                            try await serialize {
                                try Task.checkCancellation()
                                processOutput.stdout.append(availableData)
                                guard let stream else { return }
                                guard let input = await stream.onOutput(processOutput, availableData) else { return }
                                try Task.checkCancellation()
                                writeInput(input)
                            }
                        } catch {
                            terminateWithResult(.failure(error))
                        }
                    }
                }

                stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                    let availableData = handle.availableData
                    guard availableData.count > 0 else { return }
                    executionState.canceling {
                        do {
                            try await serialize {
                                try Task.checkCancellation()
                                processOutput.stderr.append(availableData)
                                guard let stream else { return }
                                guard let input = await stream.onError(processOutput, availableData) else { return }
                                try Task.checkCancellation()
                                writeInput(input)
                            }
                        } catch {
                            terminateWithResult(.failure(error))
                        }
                    }
                }

                if let timeout {
                    executionState.canceling {
                        try await Task.sleep(nanoseconds: UInt64(timeout) * NSEC_PER_SEC)
                        try Task.checkCancellation()
                        terminateWithResult(.failure(ShellError.timeout(timeout)))
                    }
                }

                process.terminationHandler = { process in
                    terminateWithResult(
                        .success(
                            ShellResult(
                                output: processOutput.stdout,
                                error: processOutput.stderr,
                                terminationReason: {
                                    switch process.terminationReason {
                                    case Process.TerminationReason.exit: "exit"
                                    case Process.TerminationReason.uncaughtSignal: "uncaughtSignal"
                                    @unknown default: "unknown"
                                    }
                                }(),
                                terminationStatus: process.terminationStatus
                            )
                        )
                    )
                }
                do {
                    try process.run()
                } catch {
                    terminateWithResult(.failure(ShellError.process(error)))
                }
            }
        }
    }
}

public enum ShellError: CustomNSError {
    public static let errorDomain: String = "ShellError"

    case input(any Error, String)
    case process(any Error)
    case terminationError(
        status: Int32,
        reason: String,
        stderr: Data,
        stderrEncoding: String.Encoding
    )
    case timeout(TimeInterval)

    public var errorCode: Int {
        switch self {
        case .input: 0
        case .process: 1
        case .terminationError: 2
        case .timeout: 3
        }
    }

    public var errorUserInfo: [String: Any] {
        switch self {
        case .input(let error, let string):
            let nsError = error as NSError
            return [
                NSUnderlyingErrorKey: "\(nsError.domain) \(nsError.code)",
                NSLocalizedDescriptionKey: "Input provided (\(string)) threw an error.",
            ]
        case .process(let error):
            let nsError = error as NSError
            return nsError.userInfo.merging([
                NSUnderlyingErrorKey: "\(nsError.domain) \(nsError.code)",
                NSLocalizedDescriptionKey: nsError.localizedDescription,
            ]) { $1 }
        case .terminationError(let status, let reason, let stderr, let stderrEncoding):
            return [
                NSLocalizedDescriptionKey: "Shell command terminated with error status (\(status)).",
                NSLocalizedFailureErrorKey: String(data: stderr, encoding: stderrEncoding) ?? "Binary stderr (\(stderr.count) bytes).",
                NSLocalizedFailureReasonErrorKey: "Shell command terminated due to reason \(reason)",
             ]
        case .timeout(let interval):
            return [
                NSLocalizedDescriptionKey: "Shell timed out after interval (\(interval)).",
            ]
        }
    }
}

public final class ShellProcessOutput: @unchecked Sendable {
    private let lock = NSRecursiveLock()

    private var _stderr: Data
    public fileprivate(set) var stderr: Data {
        get { lock.withLock { _stderr } }
        set { lock.withLock { _stderr = newValue } }
    }

    private var _stdout: Data
    public fileprivate(set) var stdout: Data {
        get { lock.withLock { _stdout } }
        set { lock.withLock { _stdout = newValue } }
    }

    public init(
        errCapacity: Int,
        outCapacity: Int
    ) {
        _stderr = Data(capacity: errCapacity)
        _stdout = Data(capacity: outCapacity)
    }
}

public struct ShellResult: Sendable {
    public let output: Data
    public let error: Data
    public var isSuccess: Bool { terminationStatus == .zero }
    public let terminationReason: String
    public let terminationStatus: Int32

    public init(
        output: Data,
        error: Data,
        terminationReason: String,
        terminationStatus: Int32
    ) {
        self.output = output
        self.error = error
        self.terminationReason = terminationReason
        self.terminationStatus = terminationStatus
    }

    public func terminationError(stderrEncoding: String.Encoding = .utf8) -> ShellError? {
        guard isSuccess else { return nil }
        return .terminationError(status: terminationStatus, reason: terminationReason, stderr: error, stderrEncoding: stderrEncoding)
    }

    public func swiftResult(stderrEncoding: String.Encoding = .utf8) -> Result<ShellResult, ShellError> {
        if let error = terminationError(stderrEncoding: stderrEncoding) {
            .failure(error)
        } else {
            .success(self)
        }
    }
}

public actor ShellSerialize {
    private var running = false
    private var queue: Array<CheckedContinuation<Void, Never>>

    public init(estimatedCapacity: Int = 16) {
        queue = Array<CheckedContinuation<Void, Never>>()
        queue.reserveCapacity(estimatedCapacity)
    }

    public func callAsFunction<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        guard !running else {
            await withCheckedContinuation { continuation in
                queue.append(continuation)
            }
            return try await performOperationAndResumeNextInQueue(operation).get()
        }
        return try await performOperationAndResumeNextInQueue(operation).get()
    }

    public func callAsFunction<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
        let throwingOperation: @Sendable () async throws -> T = { await operation() }
        return try! await callAsFunction(throwingOperation)
    }

    private func performOperationAndResumeNextInQueue<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async -> Result<T, any Error> {
        running = true
        let result: Result<T, any Swift.Error> = await {
            do {
                return .success(try await operation())
            } catch {
                return .failure(error)
            }
        }()
        if !queue.isEmpty {
            queue.removeFirst().resume()
        } else {
            running = false
        }
        return result
    }
}

public struct ShellStream: Sendable {
    fileprivate let onOutput: @Sendable (ShellProcessOutput, Data) async -> Data?
    fileprivate let onError: @Sendable (ShellProcessOutput, Data) async -> Data?
    public init(
        onOutput: @escaping @Sendable (ShellProcessOutput, Data) async -> Data?,
        onError: @escaping @Sendable (ShellProcessOutput, Data) async -> Data?
    ) {
        self.onOutput = onOutput
        self.onError = onError
    }
}

fileprivate final class _ShellExecutionState: @unchecked Sendable {
    private let lock = NSRecursiveLock()

    private var _terminateWithResultCalled: Bool = false
    func shouldTerminateWithResult() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !_terminateWithResultCalled else {
            return false
        }
        _terminateWithResultCalled = true
        return true
    }

    private var tasksToCancel: [UUID: Task<Void, any Error>] = [:]
    func canceling(_ operation: @escaping @Sendable () async throws -> Void) {
        lock.lock()
        defer {
            lock.unlock()
        }
        let uuid = UUID()
        @Sendable func removeTask() {
            lock.lock()
            tasksToCancel.removeValue(forKey: uuid)
            lock.unlock()
        }
        tasksToCancel[uuid] = Task {
            let result: Result<Void, any Error> = await {
                do {
                    return try await .success(operation())
                } catch {
                    return .failure(error)
                }
            }()
            removeTask()
            return try result.get()
        }
    }
    func cancelTasks() {
        lock.lock()
        tasksToCancel.forEach { $0.value.cancel() }
        tasksToCancel = [:]
        lock.unlock()
    }
}
