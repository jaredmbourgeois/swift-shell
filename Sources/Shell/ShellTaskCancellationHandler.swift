//  ShellTaskCancellationHandler.swift is part of the swift-shell open source project.
//
// Copyright © 2025 Jared Bourgeois
//
// Licensed under Apache License v2.0 with Runtime Library Exception
//

import Foundation

public actor ShellTaskCancellationHandler {
    public var cancelled = false
    public var tasksToCancel: [UUID: Task<Void, any Error>] = [:]

    public init() {}

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
