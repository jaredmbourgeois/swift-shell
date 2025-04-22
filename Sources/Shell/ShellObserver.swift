// ShellObserver.swift is part of the swift-shell open source project.
//
// Copyright © 2025 Jared Bourgeois
//
// Licensed under Apache License v2.0 with Runtime Library Exception
//

import Foundation

public struct ShellObserver<Error: ShellExecutionError>: Sendable {
    public let onError: (@Sendable (_ command: String, _ allOutput: ShellProcessOutput, _ stderrIncremental: Data) async -> Void)?
    public let onOutput: (@Sendable (_ command: String, _ allOutput: ShellProcessOutput, _ stdoutIncremental: Data) async -> Void)?
    public let onResult: (@Sendable (_ command: String, ShellResult<Error>) async -> Void)?

    public init(
        onError: (@Sendable (_ command: String, _ allOutput: ShellProcessOutput, _ stderrIncremental: Data) async -> Void)? = nil,
        onOutput: (@Sendable (_ command: String, _ allOutput: ShellProcessOutput, _ stdoutIncremental: Data) async -> Void)? = nil,
        onResult: (@Sendable (_ command: String, ShellResult<Error>) async -> Void)? = nil
    ) {
        self.onError = onError
        self.onOutput = onOutput
        self.onResult = onResult
    }
}
