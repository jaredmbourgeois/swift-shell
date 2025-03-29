// ShellTest.swift is part of the swift-shell open source project.
//
// Copyright © 2025 Jared Bourgeois
//
// Licensed under Apache License v2.0 with Runtime Library Exception
//

import Foundation
import XCTest

@testable import Shell

final class ShellTest: XCTestCase {
    private let timeout: TimeInterval = 3

    // MARK: - Basic Shell Tests

    func testShellAtPathEcho() async throws {
        let shell = Shell.atPath()
        let result = await shell.execute("echo 'hello world'")
        let stringProcessOutput = try result.get().stringProcessOutput()
        XCTAssertEqual("hello world\n", stringProcessOutput.stdoutTyped)
        XCTAssertEqual("", stringProcessOutput.stderrTyped)
        XCTAssertEqual(.exit, result.termination.reason)
        XCTAssertEqual(0, result.termination.status)
    }

    func testFailingCommand() async throws {
        let shell = Shell.atPath()
        let nonexistantFolder = "/\(UUID())"
        let result = await shell.execute("ls \(nonexistantFolder)")
        let stringProcessOutput = try result.processOutput.stringProcessOutput()
        XCTAssertEqual("ls: \(nonexistantFolder): No such file or directory\n", stringProcessOutput.stdoutTyped)
        XCTAssertTrue(stringProcessOutput.stderrTyped.isEmpty)
        XCTAssertEqual(.exit, result.termination.reason)
        XCTAssertEqual(1, result.termination.status)
    }

    func testCommandNotFoundWithTermination() async throws {
        let shell = Shell.atPath()
        let nonexistantCommand = UUID().uuidString
        let result = await shell.execute(
            nonexistantCommand,
            exitStatus: { status in
                switch status {
                case 0: .success
                case 127: .failure
                default: .failure
                }
            }
        )
        let stringProcessOutput = try result.processOutput.stringProcessOutput()
        XCTAssertEqual("/bin/bash: \(nonexistantCommand): command not found\n", stringProcessOutput.stdoutTyped)
        XCTAssertEqual("", stringProcessOutput.stderrTyped)
        XCTAssertEqual(127, result.termination.status)
        XCTAssertEqual(.exit, result.termination.reason)
        XCTAssertEqual("Shell command terminated with error status: 127, reason: exit.", result.error?.userInfo[NSLocalizedDescriptionKey])
    }

    func testCommandWithEnvironmentVariables() async throws {
        let shell = Shell.atPath()
        let result = await shell.execute("echo $HOME")
        let stringProcessOutput = try result.get().stringProcessOutput()
        XCTAssertFalse(stringProcessOutput.stdoutTyped.isEmpty)
        XCTAssertTrue(stringProcessOutput.stdoutTyped.contains("/"))
    }

    func testDryRun() async throws {
        let shell = Shell.atPath()
        let result = await shell.execute("ls -la /", dryRun: true)
        let stringProcessOutput = try result.get().stringProcessOutput()
        XCTAssertTrue(stringProcessOutput.stdoutTyped.contains("ls -la /"))
        XCTAssertEqual("", stringProcessOutput.stderrTyped)
    }

    // MARK: - Custom Exit Status Tests

    func testCustomExitSuccessCriteria() async throws {
        let shell = Shell.atPath()

        let result = await shell.execute("exit 1", exitStatus: { $0 == 1 ? .success : .failure })
        XCTAssertNil(result.error)
        XCTAssertEqual(1, result.termination.status)

        let failureResult = await shell.execute("exit 0", exitStatus: { $0 != 0 ? .success : .failure })
        XCTAssertNotNil(failureResult.error)
        XCTAssertEqual(0, failureResult.termination.status)
        XCTAssertEqual(.terminationError, failureResult.error?.type)
    }

    // MARK: - Timeout Tests

    func testTimeoutSuccess() async throws {
        let shell = Shell.atPath()
        // Command that completes before timeout
        let result = await shell.execute("echo 'quick command'", timeout: 1.0)
        XCTAssertNil(result.error)
        let output = try result.get().stringProcessOutput()
        XCTAssertEqual("quick command\n", output.stdoutTyped)
    }

    func testTimeoutFailure() async throws {
        let shell = Shell.atPath()
        do {
            _ = try await shell.execute("sleep 5", timeout: 0.001).get()
            XCTFail("Timeout error was expected but not thrown")
        } catch {
            XCTAssertEqual(.timeout, error.type)
        }
    }

    func testLongRunningCommandCancellation() async throws {
        let shell = Shell.atPath()
        let task = Task {
            await shell.execute("sleep 10")
        }
        try await Task.sleep(nanoseconds: NSEC_PER_SEC)
        task.cancel()
        let result = await task.value
        let error = try XCTUnwrap(result.error)
        XCTAssertEqual(.cancelled, error.type)
    }

    // MARK: - Shell Observer Tests

    func testShellObserver() async throws {
        let outputExpectation = expectation(description: "Output observer called")
        let errorExpectation = expectation(description: "Error observer called")
        let resultExpectation = expectation(description: "Result observer called")

        final class Progress: @unchecked Sendable {
            private let lock = NSLock()
            var _capturedOutput: Data?
            var capturedOutput: Data? {
                get { lock.withLock { _capturedOutput } }
                set { lock.withLock { _capturedOutput = newValue } }
            }
            var _capturedError: Data?
            var capturedError: Data?{
                get { lock.withLock { _capturedError } }
                set { lock.withLock { _capturedError = newValue } }
            }
            var _capturedResult: ShellResult?
            var capturedResult: ShellResult?{
                get { lock.withLock { _capturedResult } }
                set { lock.withLock { _capturedResult = newValue } }
            }
        }
        let progress = Progress()
        let observer = ShellObserver(
            onError: { command, output, error in
                progress.capturedError = error
                errorExpectation.fulfill()
            },
            onOutput: { command, output, data in
                progress.capturedOutput = data
                outputExpectation.fulfill()
            },
            onResult: { command, result in
                progress.capturedResult = result
                resultExpectation.fulfill()
            }
        )

        let shell = Shell.atPath(shellObserver: observer)

        // Use a command that generates both stdout and stderr
        let result = await shell.execute("echo 'test output' && echo 'test error' >&2")

        await fulfillment(of: [outputExpectation, errorExpectation, resultExpectation], timeout: timeout)

        XCTAssertNotNil(progress.capturedOutput)
        XCTAssertNotNil(progress.capturedError)
        XCTAssertNotNil(progress.capturedResult)

        // Verify the captured data matches the result
        let outputString = String(data: progress.capturedOutput ?? Data(), encoding: .utf8)
        XCTAssertTrue(outputString?.contains("test output") ?? false)

        let errorString = String(data: progress.capturedError ?? Data(), encoding: .utf8)
        XCTAssertTrue(errorString?.contains("test error") ?? false)

        XCTAssertEqual(result.termination.status, progress.capturedResult?.termination.status)
    }

    // MARK: - String Stream Tests

    func testStringStreamBasicInteraction() async throws {
        let initialPromptExpectation = expectation(description: "Received initial prompt")
        let responseExpectation = expectation(description: "Received response to command")
        let finalResponseExpectation = expectation(description: "Received final response")

        enum Step: Equatable, CustomStringConvertible {
            case waitingForInitialPrompt
            case sentCommand
            case receivedResponse
            case sentExitCommand

            var description: String {
                switch self {
                case .waitingForInitialPrompt: return "waitingForInitialPrompt"
                case .sentCommand: return "sentCommand"
                case .receivedResponse: return "receivedResponse"
                case .sentExitCommand: return "sentExitCommand"
                }
            }
        }

        let progress = TestProgress<Step>(.waitingForInitialPrompt)

        let stream = ShellStream.stringStream(
            onOutput: { processOutput, incrementalData in
                guard let incrementalString = String(data: incrementalData, encoding: .utf8) else {
                    return nil
                }

                let step = await progress.getStep()

                switch step {
                case .waitingForInitialPrompt:
                    if incrementalString.contains("READY: Please enter a command") {
                        await progress.setStep(.sentCommand)
                        initialPromptExpectation.fulfill()
                        return "echo Testing stream communication\n"
                    }
                case .sentCommand:
                    if incrementalString.contains("ECHO: Testing stream communication") {
                        await progress.setStep(.receivedResponse)
                        responseExpectation.fulfill()
                        if incrementalString.contains("READY: Enter another command") {
                            await progress.setStep(.sentExitCommand)
                            return "exit\n"
                        }
                    }
                case .receivedResponse:
                    if incrementalString.contains("READY: Enter another command") {
                        await progress.setStep(.sentExitCommand)
                        return "exit\n"
                    }
                case .sentExitCommand:
                    if incrementalString.contains("FINAL: exit") {
                        finalResponseExpectation.fulfill()
                    }
                }

                return nil
            },
            onError: { _, incrementalData in
                return nil
            }
        )

        let shell = Shell.atPath()
        let fileManager = FileManager.default
        let scriptPath = try createScript(fileManager: fileManager)
        defer {
            destroyScriptAtPath(scriptPath, fileManager: fileManager)
        }

        let task = Task {
            await shell.execute("bash \(scriptPath)", stream: stream)
        }

        await fulfillment(of: [initialPromptExpectation, responseExpectation, finalResponseExpectation], timeout: timeout)

        let result = await task.value
        let stringOutput = try result.processOutput.stringProcessOutput()

        // Verify the output contains expected responses
        XCTAssertTrue(stringOutput.stdoutTyped.contains("ECHO: Testing stream communication"))
        XCTAssertTrue(stringOutput.stdoutTyped.contains("FINAL: exit"))
        XCTAssertEqual(result.termination.status, 0)

        // Verify the state transitions happened in the expected order
        let history = await progress.getHistory()
        XCTAssertEqual(history.count, 4)
        XCTAssertEqual(history[0], .waitingForInitialPrompt)
        XCTAssertEqual(history[1], .sentCommand)
        XCTAssertEqual(history[2], .receivedResponse)
        XCTAssertEqual(history[3], .sentExitCommand)
    }

    func testStringStreamErrorHandling() async throws {
        let errorExpectation = expectation(description: "Received error in stderr")
        let finalExpectation = expectation(description: "Test completed")

        enum Step: Equatable, CustomStringConvertible {
            case waitingForInitialPrompt
            case sentInvalidCommand
            case receivedError
            case sentExitCommand
            case completed

            var description: String {
                switch self {
                case .waitingForInitialPrompt: return "waitingForInitialPrompt"
                case .sentInvalidCommand: return "sentInvalidCommand"
                case .receivedError: return "receivedError"
                case .sentExitCommand: return "sentExitCommand"
                case .completed: return "completed"
                }
            }
        }

        let progress = TestProgress<Step>(.waitingForInitialPrompt)

        let stream = ShellStream.stringStream(
            onOutput: { processOutput, incrementalData in
                guard let incrementalString = String(data: incrementalData, encoding: .utf8) else {
                    return nil
                }

                let step = await progress.getStep()
                print("onOutput: Current step: \(step), received: \(incrementalString)")

                switch step {
                case .waitingForInitialPrompt:
                    if incrementalString.contains("READY: Please enter a command") {
                        await progress.setStep(.sentInvalidCommand)
                        return "error\n"
                    }
                case .sentInvalidCommand:
                    if incrementalString.contains("READY: Enter another command") {
                        await progress.setStep(.sentExitCommand)
                        return "exit\n"
                    }
                case .receivedError:
                    if incrementalString.contains("READY: Enter another command") {
                        await progress.setStep(.sentExitCommand)
                        return "exit\n"
                    }
                case .sentExitCommand:
                    if incrementalString.contains("FINAL: exit") {
                        await progress.setStep(.completed)
                        finalExpectation.fulfill()
                    }
                case .completed:
                    break
                }
                return nil
            },
            onError: { processOutput, incrementalData in
                guard let incrementalString = String(data: incrementalData, encoding: .utf8) else {
                    return nil
                }

                print("onError: Received: \(incrementalString)")

                if incrementalString.contains("ERROR:") {
                    Task {
                        if await progress.getStep() == .sentInvalidCommand {
                            await progress.setStep(.receivedError)
                            errorExpectation.fulfill()
                        }
                    }
                }

                return nil
            }
        )

        let shell = Shell.atPath()
        let fileManager = FileManager.default
        let scriptPath = try createScript(fileManager: fileManager)
        defer {
            destroyScriptAtPath(scriptPath, fileManager: fileManager)
        }

        let task = Task {
            await shell.execute("bash \(scriptPath)", stream: stream)
        }

        await fulfillment(of: [errorExpectation, finalExpectation], timeout: timeout)

        let result = await task.value
        let stringProcessOutput = try result.processOutput.stringProcessOutput()

        XCTAssertEqual(
            "READY: Please enter a command\nRECEIVED: error\nPROCESSING...\nGENERATING ERROR\nERROR: This is an error message\nREADY: Enter another command\nFINAL: exit\nCOMPLETE\n",
            stringProcessOutput.stdoutTyped
        )
        XCTAssertEqual("", stringProcessOutput.stderrTyped)

        let history = await progress.getHistory()
        XCTAssertEqual(history.count, 5)
        XCTAssertEqual(history[0], .waitingForInitialPrompt)
        XCTAssertEqual(history[1], .sentInvalidCommand)
        XCTAssertEqual(history[2], .receivedError)
        XCTAssertEqual(history[3], .sentExitCommand)
        XCTAssertEqual(history[4], .completed)

        XCTAssertEqual(result.termination.status, 0)
    }

    // MARK: - JSON Stream Tests

    func testJSONStreamBasicInteraction() async throws {
        // Following the pattern of testStringStreamBasicInteraction but for JSON
        let initialPromptExpectation = expectation(description: "Received initial JSON prompt")
        let responseExpectation = expectation(description: "Received response to JSON command")
        let finalResponseExpectation = expectation(description: "Received final JSON response")

        enum Step: Equatable, CustomStringConvertible {
            case waitingForInitialPrompt
            case sentFirstCommand
            case receivedFirstResponse
            case sentExitCommand
            
            var description: String {
                switch self {
                case .waitingForInitialPrompt: return "waitingForInitialPrompt"
                case .sentFirstCommand: return "sentFirstCommand"
                case .receivedFirstResponse: return "receivedFirstResponse"
                case .sentExitCommand: return "sentExitCommand"
                }
            }
        }

        struct JSONCommand: Codable {
            let query: String
        }

        struct JSONResponse: Codable {
            let status: Int
            let message: String
            let step: Int?
            let query: String?
            let result: String?
            let error: String?
        }

        let progress = TestProgress<Step>(.waitingForInitialPrompt)

        // Use the stringStream approach like in testStringStreamBasicInteraction
        // This will help us handle the JSON responses more reliably
        let stream = ShellStream.stringStream(
            onOutput: { processOutput, incrementalData in
                guard let responseString = String(data: incrementalData, encoding: .utf8) else {
                    return nil
                }

                let step = await progress.getStep()

                switch step {
                case .waitingForInitialPrompt:
                    // Match the initial JSON pattern
                    if responseString.contains("\"status\": 200") && responseString.contains("\"step\": 1") {
                        await progress.setStep(.sentFirstCommand)
                        initialPromptExpectation.fulfill()
                        // Return JSON with the query
                        return "{\"query\":\"test query\"}\n"
                    }
                case .sentFirstCommand:
                    // Match the response to our first command
                    if responseString.contains("\"query\": \"test query\"") && responseString.contains("\"step\": 2") {
                        await progress.setStep(.receivedFirstResponse)
                        responseExpectation.fulfill()
                        // Send second command
                        return "{\"query\":\"exit command\"}\n"
                    }
                case .receivedFirstResponse:
                    // Match the final response
                    if responseString.contains("\"step\": 3") && responseString.contains("\"result\"") {
                        await progress.setStep(.sentExitCommand)
                        finalResponseExpectation.fulfill()
                    }
                case .sentExitCommand:
                    // Already in the final state
                    break
                }

                return nil
            },
            onError: { _, _ in
                return nil
            }
        )

        let shell = Shell.atPath()
        let fileManager = FileManager.default
        let scriptPath = try createScript(fileManager: fileManager)
        defer {
            destroyScriptAtPath(scriptPath, fileManager: fileManager)
        }

        // Create a task to execute the shell command
        let task = Task {
            await shell.execute("bash \(scriptPath) --json", stream: stream, timeout: 15.0)
        }

        // Wait for all expectations
        await fulfillment(of: [initialPromptExpectation, responseExpectation, finalResponseExpectation], 
                          timeout: timeout * 2, // Double the timeout for extra safety
                          enforceOrder: true)

        // Get the task result
        let result = await task.value
        let stringProcessOutput = try result.processOutput.stringProcessOutput()

        // Verify expected output
        XCTAssertTrue(stringProcessOutput.stdoutTyped.contains("\"status\": 200"))
        XCTAssertTrue(stringProcessOutput.stdoutTyped.contains("\"result\"") ||
                      stringProcessOutput.stdoutTyped.contains("\"message\""))
        XCTAssertEqual(.exit, result.termination.reason)
        XCTAssertEqual(0, result.termination.status)
        
        // Verify the state transitions happened in the expected order
        let history = await progress.getHistory()
        XCTAssertGreaterThanOrEqual(history.count, 3)
        XCTAssertEqual(history[0], .waitingForInitialPrompt)
        XCTAssertEqual(history[1], .sentFirstCommand)
        XCTAssertEqual(history[2], .receivedFirstResponse)
    }

    // MARK: - Serialization and Concurrency Tests

    func testShellSerializeConcurrency() async throws {
        let serialize = ShellSerialize()
        let concurrentTasks = 16
        var completedTasks = 0

        actor ConcurrencyTracker {
            var maxConcurrent = 0
            var currentConcurrent = 0
            var completedOperations = 0

            func incrementAndTrack() {
                currentConcurrent += 1
                if currentConcurrent > maxConcurrent {
                    maxConcurrent = currentConcurrent
                }
            }

            func decrement() {
                currentConcurrent -= 1
                completedOperations += 1
            }

            func getMaxConcurrent() -> Int {
                maxConcurrent
            }

            func getCompletedOperations() -> Int {
                completedOperations
            }
        }

        let tracker = ConcurrencyTracker()

        // Run multiple concurrent tasks that should be serialized
        await withTaskGroup(of: Int.self) { group in
            for i in 0..<concurrentTasks {
                group.addTask {
                    // Alternate between throwing and non-throwing calls
                    if i % 2 == 0 {
                        let result: Int = await serialize {
                            await tracker.incrementAndTrack()
                            try? await Task.sleep(nanoseconds: 1_000_000)
                            await tracker.decrement()
                            return i
                        }
                        return result
                    } else {
                        do {
                            let result: Int = try await serialize {
                                await tracker.incrementAndTrack()
                                try await Task.sleep(nanoseconds: 1_000_000)
                                await tracker.decrement()
                                return i
                            }
                            return result
                        } catch {
                            return -1
                        }
                    }
                }
            }

            for await result in group {
                XCTAssertTrue(result >= 0 && result < concurrentTasks)
                completedTasks += 1
            }
        }

        XCTAssertEqual(completedTasks, concurrentTasks)

        let completedOperations = await tracker.getCompletedOperations()
        XCTAssertEqual(completedOperations, concurrentTasks)

        let maxConcurrent = await tracker.getMaxConcurrent()
        XCTAssertEqual(maxConcurrent, 1, "Operations should be serialized, so only one should be running at a time")
    }

    // MARK: - Error Handling Tests

    func testErrorPropagation() async throws {
        let testErrorTypes: [ShellError.ErrorType] = [.cancelled, .input, .run, .terminationError, .timeout]

        for errorType in testErrorTypes {
            let customShell = Shell { _, _, _, _, _, _, _ in
                var error: ShellError

                switch errorType {
                case .cancelled:
                    error = .cancelled(description: "Test cancellation")
                case .input:
                    error = .input(error: NSError(domain: "test", code: 1),
                                  input: Data(),
                                  inputStringEncoding: .utf8)
                case .run:
                    error = .run(error: NSError(domain: "test", code: 2))
                case .terminationError:
                    error = .terminationError(termination: .init(reason: .exit, status: 1))
                case .timeout:
                    error = .timeout(timeoutInterval: 0.1)
                case .union:
                    fatalError()
                }

                return .init(
                    error: error,
                    processOutput: .init(stderr: Data(), stdout: Data()),
                    termination: .init(reason: .exit, status: 1)
                )
            }

            let result = await customShell.execute("test")
            XCTAssertNotNil(result.error)
            XCTAssertEqual(errorType, result.error?.type)

            do {
                _ = try result.get()
                XCTFail("Error should have been thrown for \(errorType)")
            } catch {
                XCTAssertEqual(errorType, error.type)
            }
        }
    }

    func testCancellationHandling() async throws {
        let cancellationExpectation = expectation(description: "Shell execution was cancelled")

        let shell = Shell.atPath()
        let task = Task {
            do {
                _ = try await shell.execute("sleep 5").get()
                XCTFail("Should not complete normally")
            } catch let error as ShellError {
                XCTAssertTrue(error.type == .cancelled || error.type == .terminationError,
                              "Expected .cancelled or .terminationError but got \(error.type)")
                cancellationExpectation.fulfill()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }

        // Wait a bit longer before cancelling to ensure the process starts
        try await Task.sleep(nanoseconds: NSEC_PER_SEC / 2)
        task.cancel()

        await fulfillment(of: [cancellationExpectation], timeout: timeout)
    }


    // MARK: - Typed Output Tests

    func testTypedProcessOutput() async throws {
        struct CustomOutput: Codable, Equatable {
            let message: String
            let count: Int
        }

        struct CustomError: Codable, Equatable {
            let errorMessage: String
            let code: Int
        }

        let outputJSON = "{\"message\":\"success\",\"count\":42}"
        let errorJSON = "{\"errorMessage\":\"failed\",\"code\":500}"

        let customShell = Shell { _, _, _, _, _, _, _ in
            .init(
                error: nil,
                processOutput: .init(
                    stderr: errorJSON.data(using: .utf8)!,
                    stdout: outputJSON.data(using: .utf8)!
                ),
                termination: .init(reason: .exit, status: 0)
            )
        }

        let result = await customShell.execute("echo test")

        // Test manual decoding
        let typedResult = try result.processOutput.typedProcessOutput(
            stdoutDecode: { data in
                try JSONDecoder().decode(CustomOutput.self, from: data)
            },
            stderrDecode: { data in
                try JSONDecoder().decode(CustomError.self, from: data)
            }
        )

        XCTAssertEqual(CustomOutput(message: "success", count: 42), typedResult.stdoutTyped)
        XCTAssertEqual(CustomError(errorMessage: "failed", code: 500), typedResult.stderrTyped)

        // Test convenience JSON decoding
        let jsonResult: ShellProcessOutput.Typed<CustomOutput, CustomError> = try result.processOutput.jsonProcessOutput()
        XCTAssertEqual(CustomOutput(message: "success", count: 42), jsonResult.stdoutTyped)
        XCTAssertEqual(CustomError(errorMessage: "failed", code: 500), jsonResult.stderrTyped)
    }

    // MARK: - Process Management Tests

    func testProcessTerminationPaths() async throws {
        let shell = Shell.atPath()

        // Test normal termination
        let normalResult = await shell.execute("exit 0")
        XCTAssertEqual(.exit, normalResult.termination.reason)
        XCTAssertEqual(0, normalResult.termination.status)
        XCTAssertNil(normalResult.error)

        // Test abnormal termination with signal
        // Note: This is platform-specific and might not work in all environments
        let signalResult = await shell.execute("kill -SEGV $$")
        XCTAssertEqual(.uncaughtSignal, signalResult.termination.reason)
        XCTAssertNotEqual(0, signalResult.termination.status)
        XCTAssertNotNil(signalResult.error)
    }

    // MARK: - Helpers

    private actor TestProgress<Step: Equatable> {
        private var step: Step
        private var history: [Step] = []

        init(_ step: Step) {
            self.step = step
            self.history = [step]
        }

        func getStep() -> Step {
            step
        }

        func setStep(_ step: Step) {
            self.step = step
            self.history.append(step)
        }

        func getHistory() -> [Step] {
            history
        }
    }

    private func createScript(fileManager: FileManager = FileManager.default) throws -> String {
        let scriptPath = fileManager.temporaryDirectory.appendingPathComponent("ShellTest-\(UUID().uuidString).sh")
        let scriptContent = """
        #!/bin/bash
        json_mode() {
            # Improved JSON handling
            echo '{"status": 200, "message": "Ready for input", "step": 1}'
            read INPUT
            INPUT_JSON=$(echo "$INPUT" | tr -d '\\n')
            QUERY=$(echo "$INPUT_JSON" | grep -o '"query":"[^"]*"' | cut -d'"' -f4)
            
            if [[ -n "$QUERY" ]]; then
                echo '{"status": 200, "message": "Processing query", "query": "'$QUERY'", "step": 2}'
                sleep 0.1  # Small delay to ensure consistent test behavior
                
                read SECOND_INPUT
                SECOND_JSON=$(echo "$SECOND_INPUT" | tr -d '\\n')
                SECOND_QUERY=$(echo "$SECOND_JSON" | grep -o '"query":"[^"]*"' | cut -d'"' -f4)
                
                if [[ -n "$SECOND_QUERY" ]]; then
                    echo '{"status": 200, "message": "Completed", "result": "Successfully processed both inputs", "step": 3}'
                    exit 0
                else
                    echo '{"status": 400, "error": "Invalid second input", "step": 2}'
                    exit 1
                fi
            else
                echo '{"status": 400, "error": "Invalid input format", "step": 1}'
                exit 1
            fi
        }
        string_mode() {
            echo "READY: Please enter a command"
            read COMMAND
            
            echo "RECEIVED: $COMMAND"
            echo "PROCESSING..."
            
            if [[ "$COMMAND" == "help" ]]; then
                echo "HELP: Available commands: help, echo, exit"
            elif [[ "$COMMAND" == "echo"* ]]; then
                ECHO_TEXT="${COMMAND#echo }"
                echo "ECHO: $ECHO_TEXT"
            elif [[ "$COMMAND" == "exit" ]]; then
                echo "EXITING"
                echo "FINAL: exit"
                exit 0
            elif [[ "$COMMAND" == "error" ]]; then
                echo "GENERATING ERROR" >&2
                echo "ERROR: This is an error message" >&2
            elif [[ "$COMMAND" == "sleep"* ]]; then
                SLEEP_TIME="${COMMAND#sleep }"
                echo "Sleeping for $SLEEP_TIME seconds..."
                sleep $SLEEP_TIME
                echo "Awake after $SLEEP_TIME seconds"
            else
                echo "ERROR: Unknown command"
                echo "Enter 'help' for available commands" >&2
            fi
            
            echo "READY: Enter another command"
            read SECOND_COMMAND
            
            echo "FINAL: $SECOND_COMMAND"
            echo "COMPLETE"
        }

        # Main execution
        if [[ "$1" == "--json" ]]; then
            json_mode
        else
            string_mode
        fi
        """
        try scriptContent.write(to: scriptPath, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)
        return scriptPath.path
    }

    private func destroyScriptAtPath(_ path: String, fileManager: FileManager) {
        try? fileManager.removeItem(atPath: path)
    }
}
