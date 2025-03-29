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
    private actor TestProgress<Step: Equatable> {
        private var step: Step
        init(_ step: Step) {
            self.step = step
        }
        func getStep() -> Step {
            step
        }
        func setStep(_ step: Step) {
            self.step = step
        }
    }

    private let timeout: TimeInterval = 3

    func testShellAtPathEcho() async throws {
        let shell = Shell.atPath()
        let result = try await shell.execute("echo helloWorld").stringResult()
        XCTAssertEqual("helloWorld\n", result.output)
        XCTAssertEqual("", result.error)
        XCTAssertEqual("exit", result.terminationReason)
        XCTAssertEqual(0, result.terminationStatus)
        XCTAssertTrue(result.isSuccess)
    }

    func testFailingCommand() async throws {
        let shell = Shell.atPath()
        let nonexistantFolder = "/\(UUID())"
        let result = try await shell.execute("ls \(nonexistantFolder)").stringResult()
        XCTAssertEqual("", result.output)
        XCTAssertEqual("ls: \(nonexistantFolder): No such file or directory\n", result.error)
        XCTAssertEqual("exit", result.terminationReason)
        XCTAssertEqual(1, result.terminationStatus)
        XCTAssertFalse(result.isSuccess)
    }

    func testTimeout() async throws {
        let shell = Shell.atPath()
        do {
            _ = try await shell.execute("sleep 1", timeout: 0.01)
            XCTFail("Timeout error not thrown")
        } catch {
            var expected = false
            if let shellError = error as? ShellError {
                switch shellError {
                case .timeout:
                    expected = true
                default:
                    break
                }
            }
            if !expected {
                XCTFail("Unknown error was thrown: \(error)")
            }
        }
    }

    func testNonexistentCommand() async throws {
        let shell = Shell.atPath()
        let nonexistantCommand = UUID().uuidString
        let result = try await shell.execute(nonexistantCommand).stringResult()
        XCTAssertEqual("", result.output)
        XCTAssertEqual("/bin/bash: \(nonexistantCommand): command not found\n", result.error)
        XCTAssertEqual("exit", result.terminationReason)
        XCTAssertEqual(127, result.terminationStatus)
        XCTAssertFalse(result.isSuccess)
    }

    func testCustomShellImplementation() async throws {
        let command = "test command"
        let expectedOutput = "Custom output for command: \(command)"
        let expectedError = "Custom error for command: \(command)"
        let expectedTerminationReason = UUID().uuidString
        let expectedTerminationStatus = Int32.random(in: .min ..< .max)
        let customShell = Shell { command, _, _, _, _, _ in
            .init(
                output: expectedOutput.data(using: .utf8)!,
                error: expectedError.data(using: .utf8)!,
                terminationReason: expectedTerminationReason,
                terminationStatus: expectedTerminationStatus
            )
        }
        let result = try await customShell.execute(command).stringResult()
        XCTAssertEqual(expectedOutput, result.output)
        XCTAssertEqual(expectedError, result.error)
        XCTAssertEqual(expectedTerminationReason, result.terminationReason)
        XCTAssertEqual(expectedTerminationStatus, result.terminationStatus)
    }

    struct TestData: Codable, Equatable {
        let name: String
        let value: Int
    }

    private let testDataJSON = "{\"name\": \"test\", \"value\": 42}"
    private let testData = TestData(name: "test", value: 42)

    func testJSONSuccess() async throws {
        let testDataJSONData = try XCTUnwrap(testDataJSON.data(using: .utf8))
        let shell = Shell { _, _, _, _, _, _ in
            .init(
                output: testDataJSONData,
                error: Data(),
                terminationReason: "",
                terminationStatus: 0
            )
        }
        let result: ShellResult.Typed<TestData, String> = try await shell.execute("").typedResult(
            decodeOutput: { try JSONDecoder().decode(TestData.self, from: $0) },
            decodeError: { String(data: $0, encoding: .utf8)! }
        )
        XCTAssertEqual(testData, result.output)
    }

    func testJSONDecodingError() async throws {
        let invalidJSON = "{ invalid json }"
        let shell = Shell { _, _, _, _, _, _ in
            ShellResult(
                output: invalidJSON.data(using: .utf8)!,
                error: Data(),
                terminationReason: "exit",
                terminationStatus: 0
            )
        }
        do {
            _ = try await shell.execute("").jsonResult() as ShellResult.Typed<TestData, String>
            XCTFail("Expected JSON decoding to fail")
        } catch {
            var expected = false
            if let decodingError = error as? DecodingError {
                switch decodingError {
                case .dataCorrupted(_):
                    expected = true
                default:
                    expected = false
                }
            }
            if !expected {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testStringDecodingError() async throws {
        let invalidData = Data([0xFF, 0xFE, 0xFD])
        let shell = Shell { _, _, _, _, _, _ in
            ShellResult(
                output: invalidData,
                error: Data(),
                terminationReason: "exit",
                terminationStatus: 0
            )
        }
        do {
            _ = try await shell.execute("echo invalid").stringResult()
            XCTFail("Expected string decoding to fail")
        } catch let error as ShellResult.StringResultError {
            switch error {
            case .decodeOutput:
                break
            default:
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testStringStream() async throws {
        let initialPromptExpectation = expectation(description: "Received initial prompt")
        let responseExpectation = expectation(description: "Received response to first command")
        let finalResponseExpectation = expectation(description: "Received final response")
        enum Step: Equatable {
            case waitingForInitialPrompt
            case sentFirstCommand
            case receivedFirstResponse
            case sentExitCommand
        }
        let progress = TestProgress<Step>(.waitingForInitialPrompt)
        let stream = ShellStream.stringStream(
            onOutput: { processOutput, incrementalData in
                guard let incrementalString = String(data: incrementalData, encoding: .utf8) else {
                    return nil
                }
                switch await progress.getStep() {
                case .waitingForInitialPrompt:
                    if incrementalString.contains("READY: Please enter a command") {
                        await progress.setStep(.sentFirstCommand)
                        initialPromptExpectation.fulfill()
                        return "echo Testing stream input\n"
                    }
                case .sentFirstCommand:
                    if incrementalString.contains("ECHO: Testing stream input") ||
                       incrementalString.contains("RECEIVED: echo Testing stream input") {
                        await progress.setStep(.receivedFirstResponse)
                        responseExpectation.fulfill()
                        if incrementalString.contains("READY: Enter another command") {
                            await progress.setStep(.sentExitCommand)
                            return "exit\n"
                        }
                    }
                case .receivedFirstResponse:
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
            onError: { _, _ in nil }
        )
        let shell = Shell.atPath()
        let fileManager = FileManager.default
        let scriptPath = try createScript(fileManager: fileManager)
        defer {
            destroyScriptAtPath(scriptPath, fileManager: fileManager)
        }
        let task = Task {
            return try await shell.execute("bash \(scriptPath)", stream: stream)
        }
        await fulfillment(of: [initialPromptExpectation, responseExpectation, finalResponseExpectation], timeout: timeout)
        let result = try await task.value
        let stringResult = try result.stringResult()
        XCTAssertTrue(stringResult.output.contains("ECHO: Testing stream input") || stringResult.output.contains("RECEIVED: echo Testing stream input"))
        XCTAssertTrue(stringResult.output.contains("FINAL: exit") || stringResult.output.contains("COMPLETE"))
        XCTAssertEqual(stringResult.terminationStatus, 0)
    }

    func testStringStreamError() async throws {
        let errorExpectation = expectation(description: "Received error in string stream")
        enum Step: Equatable {
            case waitingForInitialPrompt
            case sentInvalidCommand
            case receivedError
        }
        let progress = TestProgress<Step>(.waitingForInitialPrompt)
        let stream = ShellStream.stringStream(
            onOutput: { processOutput, incrementalData in
                guard let incrementalString = String(data: incrementalData, encoding: .utf8) else {
                    return nil
                }
                switch await progress.getStep() {
                case .waitingForInitialPrompt:
                    if incrementalString.contains("READY: Please enter a command") {
                        await progress.setStep(.sentInvalidCommand)
                        return "unknown_command\n"
                    }
                case .sentInvalidCommand:
                    if incrementalString.contains("ERROR: Unknown command") {
                        await progress.setStep(.receivedError)
                        errorExpectation.fulfill()
                        return "exit\n"
                    }
                case .receivedError:
                    break
                }
                return nil
            },
            onError: { processOutput, incrementalData in
                guard let incrementalString = String(data: incrementalData, encoding: .utf8) else {
                    return nil
                }
                if incrementalString.contains("ERROR:") || incrementalString.contains("error:") {
                    Task {
                        await progress.setStep(.receivedError)
                        errorExpectation.fulfill()
                    }
                    return "exit\n"
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
            return try await shell.execute("bash \(scriptPath)", stream: stream)
        }
        await fulfillment(of: [errorExpectation], timeout: timeout)
        let result = try await task.value
        let stringResult = try result.stringResult()
        XCTAssertTrue(stringResult.output.contains("ERROR:") || stringResult.output.contains("Unknown command"))
        XCTAssertEqual(stringResult.terminationStatus, 0)
    }

    func testJSONStream() async throws {
        let initialPromptExpectation = expectation(description: "Received initial JSON prompt")
        let responseExpectation = expectation(description: "Received response to first JSON command")
        let finalResponseExpectation = expectation(description: "Received final JSON response")
        enum Step: Equatable {
            case waitingForInitialPrompt
            case sentFirstCommand
            case receivedFirstResponse
            case sentExitCommand
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
        let stream = ShellStream.stringStream(
            onOutput: { processOutput, incrementalData in
                guard let incrementalString = String(data: incrementalData, encoding: .utf8) else {
                    return nil
                }
                switch await progress.getStep() {
                case .waitingForInitialPrompt:
                    if incrementalString.contains("\"status\": 200") && incrementalString.contains("\"step\": 1") {
                        await progress.setStep(.sentFirstCommand)
                        initialPromptExpectation.fulfill()
                        return "{\"query\":\"test query\"}\n"
                    }
                case .sentFirstCommand:
                    if incrementalString.contains("\"status\": 200") && incrementalString.contains("\"step\": 2") && incrementalString.contains("\"query\": \"test query\"") {
                        await progress.setStep(.receivedFirstResponse)
                        responseExpectation.fulfill()
                        return "{\"query\":\"exit command\"}\n"
                    }
                case .receivedFirstResponse:
                    if incrementalString.contains("\"status\": 200") && incrementalString.contains("\"step\": 3") && incrementalString.contains("\"result\"") {
                        await progress.setStep(.sentExitCommand)
                        finalResponseExpectation.fulfill()
                    }
                case .sentExitCommand:
                    break
                }
                return nil
            },
            onError: { _, _ in nil }
        )
        let shell = Shell.atPath()
        let fileManager = FileManager.default
        let scriptPath = try createScript(fileManager: fileManager)
        defer {
            destroyScriptAtPath(scriptPath, fileManager: fileManager)
        }
        let task = Task {
            return try await shell.execute("bash \(scriptPath) --json", stream: stream)
        }
        await fulfillment(of: [initialPromptExpectation, responseExpectation, finalResponseExpectation], timeout: timeout)
        let result = try await task.value
        let stringResult = try result.stringResult()
        XCTAssertTrue(stringResult.output.contains("\"status\": 200"))
        XCTAssertTrue(stringResult.output.contains("\"result\""))
        XCTAssertTrue(stringResult.output.contains("Successfully processed"))
        XCTAssertEqual(stringResult.terminationStatus, 0)
    }

    func testJSONStreamError() async throws {
        let errorExpectation = expectation(description: "Received error in JSON stream")
        enum Step: Equatable {
            case waitingForInitialPrompt
            case sentInvalidCommand
            case receivedError
        }
        let progress = TestProgress<Step>(.waitingForInitialPrompt)
        let stream = ShellStream.stringStream(
            onOutput: { processOutput, incrementalData in
                guard let incrementalString = String(data: incrementalData, encoding: .utf8) else {
                    return nil
                }

                switch await progress.getStep() {
                case .waitingForInitialPrompt:
                    if incrementalString.contains("\"status\": 200") && incrementalString.contains("\"step\": 1") {
                        await progress.setStep(.sentInvalidCommand)
                        return "{ invalid json }\n"
                    }
                case .sentInvalidCommand:
                    if incrementalString.contains("\"status\": 400") && incrementalString.contains("\"error\"") {
                        await progress.setStep(.receivedError)
                        errorExpectation.fulfill()
                        return "{\"query\":\"exit\"}\n"
                    }
                case .receivedError:
                    break
                }
                return nil
            },
            onError: { _, incrementalData in
                guard let incrementalString = String(data: incrementalData, encoding: .utf8) else {
                    return nil
                }
                if incrementalString.contains("error") || incrementalString.contains("Error") {
                    Task {
                        await progress.setStep(.receivedError)
                        errorExpectation.fulfill()
                    }
                    return "{\"query\":\"exit\"}\n"
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
            return try await shell.execute("bash \(scriptPath) --json", stream: stream)
        }
        await fulfillment(of: [errorExpectation], timeout: timeout)
        let result = try await task.value
        let stringResult = try result.stringResult()
        XCTAssertTrue(stringResult.output.contains("\"status\": 400") || stringResult.output.contains("\"error\""))
        XCTAssertEqual(stringResult.terminationStatus, 0)
    }

    func testShellStreamStringEncodingError() async throws {
        let customString = String(bytes: [0xD8, 0x00], encoding: .utf16BigEndian)!
        let stream = ShellStream.stringStream(
            encoding: .ascii,
            onOutput: { _, _ in return customString },
            onError: { _, _ in return nil }
        )
        let shell = Shell { _, _, _, _, stream, _ in
            let outputData = "test".data(using: .utf8)!
            return ShellResult(
                output: outputData,
                error: Data(),
                terminationReason: "exit",
                terminationStatus: 0
            )
        }
        let result = try await shell.execute("echo test", stream: stream)
        XCTAssertEqual(result.output, "test".data(using: .utf8))
        XCTAssertEqual(result.terminationStatus, 0)
    }

    func testShellStreamTypedEncodingError() async throws {
        let stream = ShellStream.typedStream(
            encodeInput: { (_: String) -> Data in
                throw ShellStream.StringStreamError.encode
            },
            onOutput: { _, _ in return "input" },
            onOutputDecode: { data in
                return String(data: data, encoding: .utf8) ?? ""
            },
            onError: { _, _ in return nil },
            onErrorDecode: { data in
                return String(data: data, encoding: .utf8) ?? ""
            }
        )
        let shell = Shell { _, _, _, _, stream, _ in
            let outputData = "test".data(using: .utf8)!
            return ShellResult(
                output: outputData,
                error: Data(),
                terminationReason: "exit",
                terminationStatus: 0
            )
        }
        let result = try await shell.execute("echo test", stream: stream)
        XCTAssertEqual(result.output, "test".data(using: .utf8))
        XCTAssertEqual(result.terminationStatus, 0)
    }

    func testShellResultTypedIsSuccess() async throws {
        let successResult = ShellResult.Typed<String, String>(
            output: "success output",
            error: "no error",
            terminationReason: "exit",
            terminationStatus: 0
        )
        XCTAssertTrue(successResult.isSuccess)
        let failureResult = ShellResult.Typed<String, String>(
            output: "failure output",
            error: "error occurred",
            terminationReason: "exit",
            terminationStatus: 1
        )
        XCTAssertFalse(failureResult.isSuccess)
    }

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
        for i in 0..<concurrentTasks {
            if i % 2 == 0 {
                let result: Int = await serialize {
                    await tracker.incrementAndTrack()
                    try? await Task.sleep(nanoseconds: 1_000_000)
                    await tracker.decrement()
                    return i
                }
                XCTAssertEqual(result, i)
            } else {
                let result: Int = try await serialize {
                    await tracker.incrementAndTrack()
                    try await Task.sleep(nanoseconds: 1_000_000)
                    await tracker.decrement()
                    return i
                }
                XCTAssertEqual(result, i)
            }
            completedTasks += 1
        }
        XCTAssertEqual(completedTasks, concurrentTasks)

        let completedOperations = await tracker.getCompletedOperations()
        XCTAssertEqual(completedOperations, concurrentTasks)

        let maxConcurrent = await tracker.getMaxConcurrent()
        XCTAssertEqual(maxConcurrent, 1)
    }

    func testShellInputError() async throws {
        let inputErrorExpectation = expectation(description: "Input error was thrown")
        let shell = Shell { command, _, _, _, stream, _ in
            if stream != nil {
                throw ShellError.input(NSError(domain: "test", code: 0), "Test input error")
            }
            return ShellResult(
                output: Data(),
                error: Data(),
                terminationReason: "exit",
                terminationStatus: 0
            )
        }
        let stream = ShellStream(
            onOutput: { _, _ in return Data() },
            onError: { _, _ in return nil }
        )
        do {
            _ = try await shell.execute("test command", stream: stream)
            XCTFail("Expected input error but no error was thrown")
        } catch let error as ShellError {
            switch error {
            case .input:
                inputErrorExpectation.fulfill()
            default:
                XCTFail("Expected input error but got different error: \(error)")
            }
        } catch {
            XCTFail("Expected ShellError.input but got unexpected error: \(error)")
        }
        await fulfillment(of: [inputErrorExpectation], timeout: timeout)
    }

    func testShellProcessError() async throws {
        let processErrorExpectation = expectation(description: "Process error was thrown")
        let shell = Shell.atPath("non_existent_shell_path")
        do {
            _ = try await shell.execute("echo test")
            XCTFail("Expected process error")
        } catch let error as ShellError {
            switch error {
            case .process:
                processErrorExpectation.fulfill()
            default:
                XCTFail("Unexpected error type: \(error)")
            }
        }
        await fulfillment(of: [processErrorExpectation], timeout: timeout)
    }

    private func destroyScriptAtPath(_ path: String, fileManager: FileManager) {
        try? fileManager.removeItem(atPath: path)
    }

    private func createScript(fileManager: FileManager) throws -> String {
        let scriptPath = fileManager.temporaryDirectory.appendingPathComponent("ShellTest-\(UUID().uuidString).sh")
        let scriptContent = """
        #!/bin/bash
        # interactive_test.sh - A script for testing interactive shell processes

        # Function to handle JSON mode
        json_mode() {
            echo '{"status": 200, "message": "Ready for input", "step": 1}'
            read INPUT
            INPUT_JSON=$(echo "$INPUT" | tr -d '\\n')
            QUERY=$(echo "$INPUT_JSON" | grep -o '"query":"[^"]*"' | cut -d'"' -f4)
            
            if [[ -n "$QUERY" ]]; then
                echo '{"status": 200, "message": "Processing query", "query": "'$QUERY'", "step": 2}'
                read SECOND_INPUT
                SECOND_JSON=$(echo "$SECOND_INPUT" | tr -d '\\n')
                SECOND_QUERY=$(echo "$SECOND_JSON" | grep -o '"query":"[^"]*"' | cut -d'"' -f4)
                
                if [[ -n "$SECOND_QUERY" ]]; then
                    echo '{"status": 200, "message": "Completed", "result": "Successfully processed both inputs", "step": 3}'
                else
                    echo '{"status": 400, "error": "Invalid second input", "step": 2}'
                fi
            else
                echo '{"status": 400, "error": "Invalid input format", "step": 1}'
            fi
        }

        # Function to handle string mode
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
                exit 0
            else
                echo "ERROR: Unknown command"
                echo "Enter 'help' for available commands"
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

}
