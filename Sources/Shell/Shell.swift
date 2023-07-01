import Foundation

public enum Shell {
  public static let defaultShellPath = "/bin/bash"

  public enum Result: Equatable {
    case output(String)
    case error(String)
    case failure

    public var description: String {
      switch self {
      case .output(let string): return string
      case .error(let string): return string
      case .failure: return "failure"
      }
    }
  }
}

public protocol ShellExecutor: Sendable {
  func `do`(_ command: String, taskPriority: TaskPriority?) async -> Shell.Result
  func sudo(_ command: String, taskPriority: TaskPriority?) async -> Shell.Result
}

extension ShellExecutor {
  public func `do`(_ command: String) async -> Shell.Result {
    await `do`(command, taskPriority: nil)
  }

  public func sudo(_ command: String) async -> Shell.Result {
    await sudo(command, taskPriority: nil)
  }
}

extension Shell {
  public actor Executor: ShellExecutor, @unchecked Sendable {
    public nonisolated let shellPath: String

    public init(shellPath: String = Shell.defaultShellPath) {
      self.shellPath = shellPath
    }
  }
}

extension Shell.Executor {
  public func `do`(_ command: String, taskPriority: TaskPriority?) async -> Shell.Result {
    await shellProcess(command, taskPriority: taskPriority)
  }

  public func sudo(_ command: String, taskPriority: TaskPriority?) async -> Shell.Result {
    await shellProcess(command, taskPriority: taskPriority)
  }

  private func shellProcess(
    _ command: String,
    taskPriority: TaskPriority?
  ) async -> Shell.Result {
    await withCheckedContinuation { continuation in
      Task(priority: taskPriority) {
        var result: Shell.Result = .failure
        defer {
          continuation.resume(with: .success(result))
        }
        let shellUrl = URL(fileURLWithPath: shellPath)
        let process = Process()
        process.executableURL = shellUrl
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.arguments = ["-c", command]
        do {
          try Task.checkCancellation()
          try process.run()
          process.waitUntilExit()
          try Task.checkCancellation()
        } catch {
          result = .error(String(reflecting: error))
        }
        guard process.terminationStatus == 0 else {
          return
        }
        if let output = String(
          data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
          encoding: .utf8
        ) {
          result = .output(output)
        } else if let error = String(
          data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
          encoding: .utf8
        ) {
          result = .error(error)
        }
        print("swift-shell\n\tcommand: \(command)\n\tresult: \(result.description)")
      }
    }
  }
}
