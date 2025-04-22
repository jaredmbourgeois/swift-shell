// ShellSerialize.swift is part of the swift-shell open source project.
//
// Copyright © 2025 Jared Bourgeois
//
// Licensed under Apache License v2.0 with Runtime Library Exception
//

import Foundation

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
