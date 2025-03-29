// Shell+AtPath.swift is part of the swift-shell open source project.
//
// Copyright © 2025 Jared Bourgeois
//
// Licensed under Apache License v2.0 with Runtime Library Exception
//

import Foundation

public enum ShellProcessCancellationLocation: String, Sendable {
    case checker
    case processExit
    case stderrReadabilitySerialize
    case stderrReadabilityStart
    case stderrReadabilityWriteInput
    case stdoutReadabilitySerialize
    case stdoutReadabilityStart
    case stdoutReadabilityWriteInput
}

public enum ShellProcessTerminationReason: Sendable, Equatable {
    case cancelled(ShellError)
    case exited
    case inputFailure(ShellError)
    case runFailure(ShellError)
    case terminated
    case timeout(ShellError)

    public var shellError: ShellError? {
        switch self {
        case .cancelled(let shellError): shellError
        case .exited: nil
        case .inputFailure(let shellError): shellError
        case .runFailure(let shellError): shellError
        case .terminated: nil
        case .timeout(let shellError): shellError
        }
    }
}

public final class ReadWriteLock<Value>: @unchecked Sendable {
    private var lock = pthread_rwlock_t()
    private var _value: Value
    public var value: Value {
        get {
            pthread_rwlock_rdlock(&lock)
            let value = _value
            pthread_rwlock_unlock(&lock)
            return value
        }
        set {
            pthread_rwlock_wrlock(&lock)
            _value = newValue
            pthread_rwlock_unlock(&lock)
        }
    }

    public init(_ value: Value) {
        guard pthread_rwlock_init(&lock, nil) == 0 else {
            fatalError("pthread_rwlock_init failed")
        }
        self._value = value
    }

    deinit {
        pthread_rwlock_destroy(&lock)
    }

    @discardableResult
    public func reading<T>(_ read: (inout Value) throws -> T) rethrows -> T {
        pthread_rwlock_rdlock(&lock)
        defer { pthread_rwlock_unlock(&lock) }
        return try read(&_value)
    }

    @discardableResult
    public func writing<T>(_ read: (inout Value) throws -> T) rethrows -> T {
        pthread_rwlock_wrlock(&lock)
        defer { pthread_rwlock_unlock(&lock) }
        return try read(&_value)
    }
}

public struct ShellProcess: Sendable {
    public struct RunState: OptionSet, Sendable {
        public static let started = RunState(rawValue: 1 << 0)
        public static let exited = RunState(rawValue: 1 << 1)
        public static let runFailed = RunState(rawValue: 1 << 2)
        public static let terminateRequested = RunState(rawValue: 1 << 3)
        public static let terminated = RunState(rawValue: 1 << 4)
        public let rawValue: UInt
        public init(rawValue: UInt) {
            self.rawValue = rawValue
        }
        public var isRunning: Bool {
            contains(.started) && !(contains(.exited) || contains(.terminated))
        }
    }

    public var runState: RunState
    public var stderr: Data
    public var stdout: Data
    public var terminationContinuation: CheckedContinuation<Bool, Never>?
    public var terminationReason: ShellProcessTerminationReason?

    public init(
        errCapacity: Int,
        outCapacity: Int
    ) {
        runState = []
        stderr = Data(capacity: errCapacity)
        stdout = Data(capacity: outCapacity)
    }

    public func makeOutput() -> ShellProcessOutput {
        .init(stderr: stderr, stdout: stdout)
    }
}

public actor ShellTaskHandler {
    public var cancelled = false
    public var tasksToCancel: [UUID: Task<Void, any Error>] = [:]

    public nonisolated func cancelling(_ operation: @escaping @Sendable () async throws -> Void) {
        Task {
            await _cancelling(operation)
        }
    }

    private func _cancelling(_ operation: @escaping @Sendable () async throws -> Void) {
        let uuid = UUID()
        tasksToCancel[uuid] = Task {
            let result: Result<Void, any Error> = await {
                do {
                    return try await .success(operation())
                } catch {
                    return .failure(error)
                }
            }()
            tasksToCancel.removeValue(forKey: uuid)
            return try result.get()
        }
    }

    public func cancelTasksIfNeeded() {
        guard !cancelled else { return }
        tasksToCancel.forEach { $0.value.cancel() }
        tasksToCancel = [:]
        cancelled = true
    }
}

extension Shell {
    /// Defaults to `/bin/bash`.
    public static func atPath(
        _ shellPath: String = "/bin/bash",
        defaultEstimatedErrorCapacity: Int = 4_096,
        defaultEstimatedOutputCapacity: Int = 16_384,
        shellObserver: ShellObserver? = nil,
        shellTerminationForReason: @escaping @Sendable (ShellProcessTerminationReason, Process) -> ShellTermination = { reason, process in
            return switch reason {
            case .cancelled: .init(reason: .uncaughtSignal, status: ShellTermination.statusForCancellationDefault)
            case .exited: .init(reason: .init(process.terminationReason), status: process.terminationStatus)
            case .inputFailure: .init(reason: .uncaughtSignal, status: 1002)
            case .runFailure: .init(reason: .uncaughtSignal, status: 1003)
            case .terminated: .init(reason: .init(process.terminationReason), status: process.terminationStatus)
            case .timeout: .init(reason: .uncaughtSignal, status: 1005)
            }
        },
        stringEncoding: String.Encoding = .utf8
    ) -> Shell {
        .init { command, dryRun, estimatedOutputSize, estimatedErrorSize, exitStatus, stream, timeout in
            let process = Process()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    process.executableURL = URL(fileURLWithPath: shellPath)

                    let command = dryRun ? "echo \"\(command)\"" : command
                    process.arguments = ["-c", command]

                    let stderrPipe = Pipe()
                    let stdinPipe = Pipe()
                    let stdoutPipe = Pipe()
                    process.standardError = stderrPipe
                    process.standardInput = stdinPipe
                    process.standardOutput = stdoutPipe

                    let shellProcess = ReadWriteLock(
                        ShellProcess(
                            errCapacity: estimatedErrorSize ?? defaultEstimatedErrorCapacity,
                            outCapacity: estimatedOutputSize ?? defaultEstimatedOutputCapacity
                        )
                    )
                    let serializeIO = ShellSerialize()
                    let serializeTermination = ShellSerialize()
                    let taskHandler = ShellTaskHandler()

                    @Sendable func terminateWithReason(_ terminationReason: ShellProcessTerminationReason, continuation: CheckedContinuation<ShellResult, Never>) async {
                        await serializeTermination {
                            let shouldTerminate = await withCheckedContinuation { terminationContinuation in
                                shellProcess.writing {
                                    let processIsRunning = process.isRunning
                                    if processIsRunning && !$0.runState.contains(.terminateRequested) {
                                        $0.runState.insert(.terminateRequested)
                                        process.terminate()
                                    }
                                    if $0.terminationReason == nil {
                                        $0.terminationReason = terminationReason
                                        let waitForTermination = processIsRunning || (($0.runState.contains(.started) && !($0.runState.contains(.exited) || $0.runState.contains(.terminated))))
                                        if waitForTermination {
                                            $0.terminationContinuation = terminationContinuation
                                        } else {
                                            terminationContinuation.resume(returning: true)
                                        }
                                        Task {
                                            await taskHandler.cancelTasksIfNeeded()
                                        }
                                    } else {
                                        terminationContinuation.resume(returning: false)
                                    }
                                }
                            }
                            guard shouldTerminate else {
                                return
                            }
                            let processOutput = shellProcess.value.makeOutput()

                            try? stdinPipe.fileHandleForWriting.close()
                            try? stderrPipe.fileHandleForReading.close()
                            try? stdoutPipe.fileHandleForReading.close()
                            stderrPipe.fileHandleForReading.readabilityHandler = nil
                            stdoutPipe.fileHandleForReading.readabilityHandler = nil

                            let termination = shellTerminationForReason(terminationReason, process)
                            let result = ShellResult(
                                error: {
                                    switch exitStatus(termination.status) {
                                    case .cancelled: .cancelled(description: "exit status \(termination.status)")
                                    case .failure: terminationReason.shellError ?? .terminationError(termination: termination)
                                    case .success: terminationReason.shellError
                                    }
                                }(),
                                processOutput: processOutput,
                                termination: termination
                            )
                            continuation.resume(returning: result)
                            await shellObserver?.onResult?(command, result)
                        }
                    }

                    @Sendable func cancellationFromLocation(_ location: ShellProcessCancellationLocation) -> ShellError? {
                        do {
                            try Task.checkCancellation()
                            return nil
                        } catch {
                            return ShellError.cancelled(description: location.rawValue)
                        }
                    }

                    @Sendable func writeInput(_ data: Data) -> ShellError? {
                        guard data.count > 0 else { return nil }
                        do {
                            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
                            return nil
                        } catch {
                            return .input(error: error, input: data, inputStringEncoding: stringEncoding)
                        }
                    }

                    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                        let availableData = handle.availableData
                        guard availableData.count > 0 else { return }
                        taskHandler.cancelling {
                            if let cancellationError = cancellationFromLocation(.stdoutReadabilitySerialize) {
                                await terminateWithReason(.cancelled(cancellationError), continuation: continuation)
                                return
                            }

                            await serializeIO {
                                if let cancellationError = cancellationFromLocation(.stdoutReadabilityStart) {
                                    await terminateWithReason(.cancelled(cancellationError), continuation: continuation)
                                    return
                                }

                                let processOutput = shellProcess.writing {
                                    $0.stdout += availableData
                                    return $0.makeOutput()
                                }
                                defer {
                                    if let observerOnOutput = shellObserver?.onOutput {
                                        Task {
                                            await observerOnOutput(command, processOutput, availableData)
                                        }
                                    }
                                }
                                guard let stream else { return }
                                guard let input = await stream.onOutput(processOutput, availableData) else { return }

                                if let cancellationError = cancellationFromLocation(.stdoutReadabilityWriteInput) {
                                    await terminateWithReason(.cancelled(cancellationError), continuation: continuation)
                                    return
                                }

                                if let inputError = writeInput(input) {
                                    await terminateWithReason(.inputFailure(inputError), continuation: continuation)
                                }
                            }
                        }
                    }

                    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                        let availableData = handle.availableData
                        guard availableData.count > 0 else { return }
                        taskHandler.cancelling {
                            if let cancellationError = cancellationFromLocation(.stderrReadabilitySerialize) {
                                await terminateWithReason(.cancelled(cancellationError), continuation: continuation)
                                return
                            }

                            try await serializeIO { () throws(ShellError) -> Void in
                                if let cancellationError = cancellationFromLocation(.stderrReadabilityStart) {
                                    await terminateWithReason(.cancelled(cancellationError), continuation: continuation)
                                    return
                                }

                                let processOutput = shellProcess.writing {
                                    $0.stdout += availableData
                                    return $0.makeOutput()
                                }
                                defer {
                                    if let observerOnError = shellObserver?.onError {
                                        Task {
                                            await observerOnError(command, processOutput, availableData)
                                        }
                                    }
                                }
                                guard let stream else { return }
                                guard let input = await stream.onError(processOutput, availableData) else { return }

                                if let cancellationError = cancellationFromLocation(.stderrReadabilityWriteInput) {
                                    await terminateWithReason(.cancelled(cancellationError), continuation: continuation)
                                    return
                                }

                                if let inputError = writeInput(input) {
                                    await terminateWithReason(.inputFailure(inputError), continuation: continuation)
                                }
                            }
                        }
                    }

                    if let timeout {
                        taskHandler.cancelling {
                            try await Task.sleep(nanoseconds: UInt64(timeout) * NSEC_PER_SEC)
                            try Task.checkCancellation()
                            await terminateWithReason(.timeout(.timeout(timeoutInterval: timeout)), continuation: continuation)
                        }
                    }

                    process.terminationHandler = { process in
                        process.terminationHandler = nil
                        shellProcess.writing {
                            $0.runState.insert(.terminated)
                            if let continuation = $0.terminationContinuation {
                                $0.terminationContinuation = nil
                                continuation.resume(returning: true)
                            } else {
                                Task {
                                    await terminateWithReason(.terminated, continuation: continuation)
                                }
                            }
                        }
                    }

                    taskHandler.cancelling {
                        do {
                            try process.run()
                            shellProcess.writing {
                                $0.runState.insert(.started)
                            }
                            await withCheckedContinuation { continuation in
                                process.waitUntilExit()
                                continuation.resume()
                            }
                            shellProcess.writing {
                                $0.runState.insert(.exited)
                            }
                            if let cancellationError = cancellationFromLocation(.processExit) {
                                await terminateWithReason(.cancelled(cancellationError), continuation: continuation)
                            } else {
                                await terminateWithReason(.exited, continuation: continuation)
                            }
                        } catch {
                            shellProcess.writing {
                                $0.runState.insert(.runFailed)
                            }
                            await terminateWithReason(.runFailure(.run(error: error)), continuation: continuation)
                        }
                    }
                }
            } onCancel: {
                if process.isRunning {
                    process.terminate()
                }
            }
        }
    }
}
