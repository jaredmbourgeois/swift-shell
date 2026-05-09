// Shell+AtPath.swift is part of the swift-shell open source project.
//
// Copyright © 2025 Jared Bourgeois
//
// Licensed under Apache License v2.0 with Runtime Library Exception
//

import Foundation

public typealias ShellAtPath = Shell<ShellAtPathError>

extension ShellAtPath {
    /// Defaults to `/bin/bash`.
    public static func atPath(
        _ shellPath: String = "/bin/bash",
        defaultEstimatedErrorCapacity: Int = 4_096,
        defaultEstimatedOutputCapacity: Int = 16_384,
        shellObserver: ShellObserver<ShellAtPathError>? = nil,
        sleep: @escaping @Sendable (_ seconds: TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
        },
        stringEncoding: String.Encoding = .utf8
    ) -> Shell {
        .init { command, dryRun, estimatedOutputSize, estimatedErrorSize, statusesForResult, stream, timeout in
            let process = Process()
            var terminationStatusForCancellation: ShellTermination.Status {
                statusesForResult.cancellations.first ?? .defaultCancellationStatus
            }
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
                        ShellAtPathProcess(
                            errCapacity: estimatedErrorSize ?? defaultEstimatedErrorCapacity,
                            outCapacity: estimatedOutputSize ?? defaultEstimatedOutputCapacity
                        )
                    )
                    let serializeIO = ShellSerialize()
                    let serializeTermination = ShellSerialize()
                    let taskCancellationHandler = ShellTaskCancellationHandler()

                    @Sendable func terminateWithReason(_ terminationReason: ShellAtPathProcess.TerminationReason, continuation: CheckedContinuation<ShellResult<ShellAtPathError>, Never>) async {
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
                                            await taskCancellationHandler.cancelTasksIfNeeded()
                                        }
                                    } else {
                                        terminationContinuation.resume(returning: false)
                                    }
                                }
                            }
                            guard shouldTerminate else {
                                return
                            }
                            // Drain pipes before snapshotting output. Without this, fast-completing
                            // processes can return with empty stdout/stderr: the process exits and
                            // `waitUntilExit()` returns before the readability handlers have flushed
                            // the last chunks from the pipe's kernel buffer.
                            //
                            // The handlers above append synchronously inside `shellProcess.writing`,
                            // so once we acquire the write lock here we know no in-flight handler
                            // invocation is mid-append. Nilling the handlers first means Foundation
                            // won't dispatch new invocations after this point. The final
                            // `availableData` reads pick up anything the kernel buffered post-EOF
                            // that no handler will fire for.
                            //
                            // Pre-1.4.1 this manifested as silent empty-stdout on macOS / older
                            // Swift, and as a libdispatch semaphore-wait segfault on Swift 6.3.1 /
                            // Linux under parallel use.
                            stderrPipe.fileHandleForReading.readabilityHandler = nil
                            stdoutPipe.fileHandleForReading.readabilityHandler = nil
                            shellProcess.writing { state in
                                let stderrFinal = stderrPipe.fileHandleForReading.availableData
                                let stdoutFinal = stdoutPipe.fileHandleForReading.availableData
                                if !stderrFinal.isEmpty { state.stderr += stderrFinal }
                                if !stdoutFinal.isEmpty { state.stdout += stdoutFinal }
                            }
                            let processOutput = shellProcess.value.makeOutput()

                            try? stdinPipe.fileHandleForWriting.close()
                            try? stderrPipe.fileHandleForReading.close()
                            try? stdoutPipe.fileHandleForReading.close()

                            let (error, termination): (ShellAtPathError?, ShellTermination) = switch terminationReason {
                            case .error(let error): (error, error.termination)
                            default: {
                                let terminationStatus = process.terminationStatus
                                return (
                                    {
                                        if statusesForResult.cancellations.contains(where: { $0 == terminationStatus }) {
                                            return ShellAtPathError.cancelled(command: command, location: .terminationStatus, status: terminationStatus)
                                        }
                                        if !statusesForResult.successes.contains(where: { $0 == terminationStatus }) {
                                            return ShellAtPathError.termination(command: command, status: terminationStatus)
                                        }
                                        return nil
                                    }(),
                                    ShellTermination(
                                        reason: .init(process.terminationReason),
                                        status: process.terminationStatus
                                    )
                                )
                            }()
                            }
                            let result = ShellResult<ShellAtPathError>.init(
                                error: error,
                                processOutput: processOutput,
                                termination: termination
                            )
                            continuation.resume(returning: result)
                            await shellObserver?.onResult?(command, result)
                        }
                    }

                    @Sendable func shouldContinue(from location: ShellAtPathProcess.CancellationLocation) async -> Bool {
                        do {
                            try Task.checkCancellation()
                            return true
                        } catch {
                            await terminateWithReason(.error(.cancelled(command: command, location: location, status: statusesForResult.cancellations.first ?? .defaultCancellationStatus)), continuation: continuation)
                            return false
                        }
                    }

                    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                        // Read pipe + append SYNCHRONOUSLY inside the lock — both as one atomic
                        // critical section. The pre-1.4.1 architecture deferred the append into a
                        // `taskCancellationHandler.cancelling` Task that hopped through an actor
                        // before reaching `shellProcess.writing`. That created a window where the
                        // kernel pipe buffer had been drained by `availableData` but the data wasn't
                        // yet in `shellProcess.stdout`. terminateWithReason racing against that
                        // window saw incomplete output. Reading INSIDE the writing block makes
                        // read+append indivisible w.r.t. concurrent drains and other handlers.
                        let (availableData, processOutput) = shellProcess.writing { state -> (Data, ShellProcessOutput) in
                            let data = handle.availableData
                            if !data.isEmpty { state.stdout += data }
                            return (data, state.makeOutput())
                        }
                        guard !availableData.isEmpty else {
                            return
                        }
                        // Stream callbacks + observers may be async; they run after the append
                        // and don't affect captured-output correctness.
                        taskCancellationHandler.cancelling {
                            guard await shouldContinue(from: .stdoutReadabilitySerialize) else {
                                return
                            }
                            await serializeIO {
                                guard await shouldContinue(from: .stdoutReadabilityStart) else {
                                    return
                                }
                                defer {
                                    if let observerOnOutput = shellObserver?.onOutput {
                                        Task {
                                            await observerOnOutput(command, processOutput, availableData)
                                        }
                                    }
                                }
                                guard let stream else {
                                    return
                                }
                                let input: Data?
                                do {
                                    input = try await stream.onOutput(processOutput, availableData)
                                } catch {
                                    await terminateWithReason(.error(.streamOnOut(command: command, error: error)), continuation: continuation)
                                    return
                                }
                                guard let input,
                                      input.count > 0,
                                      await shouldContinue(from: .stdoutReadabilityWriteInput) else {
                                    return
                                }
                                do {
                                    try stdinPipe.fileHandleForWriting.write(contentsOf: input)
                                } catch {
                                    await terminateWithReason(
                                        .error(
                                            .streamInputWriteOut(
                                                command: command,
                                                error: error,
                                                input: input,
                                                inputStringEncoding: stringEncoding
                                            )
                                        ),
                                        continuation: continuation
                                    )
                                }
                            }
                        }
                    }

                    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                        // Read pipe + append SYNCHRONOUSLY inside the lock (see stdout handler
                        // comment for rationale).
                        let (availableData, processOutput) = shellProcess.writing { state -> (Data, ShellProcessOutput) in
                            let data = handle.availableData
                            if !data.isEmpty { state.stderr += data }
                            return (data, state.makeOutput())
                        }
                        guard !availableData.isEmpty else {
                            return
                        }
                        taskCancellationHandler.cancelling {
                            guard await shouldContinue(from: .stderrReadabilitySerialize) else {
                                return
                            }
                            await serializeIO {
                                guard await shouldContinue(from: .stderrReadabilityStart) else {
                                    return
                                }
                                defer {
                                    if let observerOnError = shellObserver?.onError {
                                        Task {
                                            await observerOnError(command, processOutput, availableData)
                                        }
                                    }
                                }
                                guard let stream else {
                                    return
                                }
                                let input: Data?
                                do {
                                    input = try await stream.onError(processOutput, availableData)
                                } catch {
                                    await terminateWithReason(.error(.streamOnErr(command: command, error: error)), continuation: continuation)
                                    return
                                }
                                guard let input,
                                      input.count > 0,
                                      await shouldContinue(from: .stderrReadabilityWriteInput) else {
                                    return
                                }
                                do {
                                    try stdinPipe.fileHandleForWriting.write(contentsOf: input)
                                } catch {
                                    await terminateWithReason(
                                        .error(
                                            .streamInputWriteErr(
                                                command: command,
                                                error: error,
                                                input: input,
                                                inputStringEncoding: stringEncoding
                                            )
                                        ),
                                        continuation: continuation
                                    )
                                }
                            }
                        }
                    }

                    if let timeout {
                        taskCancellationHandler.cancelling {
                            try await sleep(timeout)
                            try Task.checkCancellation()
                            await terminateWithReason(.error(.timeout(command: command, timeoutInterval: timeout)), continuation: continuation)
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
                                    await terminateWithReason(.terminate, continuation: continuation)
                                }
                            }
                        }
                    }

                    taskCancellationHandler.cancelling {
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
                            guard await shouldContinue(from: .processExit) else {
                                return
                            }
                            await terminateWithReason(.exit, continuation: continuation)
                        } catch {
                            shellProcess.writing {
                                $0.runState.insert(.runFailed)
                            }
                            await terminateWithReason(.error(.run(command: command, error: error)), continuation: continuation)
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

public struct ShellAtPathProcess: Sendable {
    public enum CancellationLocation: String, Sendable {
        case processExit
        case stderrReadabilitySerialize
        case stderrReadabilityStart
        case stderrReadabilityWriteInput
        case stdoutReadabilitySerialize
        case stdoutReadabilityStart
        case stdoutReadabilityWriteInput
        case terminationStatus
    }

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

    public enum TerminationReason: Sendable, Equatable {
        case error(ShellAtPathError)
        case exit
        case terminate

        public var error: ShellAtPathError? {
            switch self {
            case .error(let error): error
            case .exit: nil
            case .terminate: nil
            }
        }
    }

    public var runState: RunState
    public var stderr: Data
    public var stdout: Data
    public var terminationContinuation: CheckedContinuation<Bool, Never>?
    public var terminationReason: ShellAtPathProcess.TerminationReason?

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
