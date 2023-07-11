import Foundation

public enum Shell {
  public static let defaultShellPath = "/bin/bash"

  public enum Result: Equatable {
    case standardOutput(String)
    case standardError(String)
    case failure(String)

    public var description: String {
      let name: String
      let value: String
      switch self {
      case .standardOutput(let string):
        name = "output"
        value = string
      case .standardError(let string):
        name = "error"
        value = string
      case .failure(let string):
        name = "failure"
        value = string
      }
      let newLine = value.last == "\n" ? "" : "\n"
      return "\(name)(\n\(value)\(newLine)\t)"
    }
  }
}

public protocol ShellExecutor: AnyActor {
  var shellPath: String { get }
  var printsStandardOutput: Bool { get }
  var printsFailure: Bool { get }

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
    public nonisolated let printsStandardOutput: Bool
    public nonisolated let printsFailure: Bool

    public init(
      shellPath: String = Shell.defaultShellPath,
      printsOutput: Bool = false,
      printsFailure: Bool = false
    ) {
      self.shellPath = shellPath
      self.printsStandardOutput = printsOutput
      self.printsFailure = printsFailure
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
        let result: Shell.Result
        defer {
          let prints: Bool
          switch result {
          case .standardOutput: prints = printsStandardOutput
          case .standardError: prints = printsStandardOutput
          case .failure: prints = printsFailure
          }
          if prints {
            print("swift-shell\n\tcommand:\n\(command)\n\tresult: \(result.description)")
          }
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
        var processError: (any Error)?
        do {
          try Task.checkCancellation()
          try process.run()
          process.waitUntilExit()
        } catch {
          processError = error
        }
        guard process.terminationStatus == 0 else {
          result = .failure("Process terminated with reason: \(process.terminationReason), status: \(process.terminationStatus)")
          return
        }
        if let processError {
          result = .failure("Process error: \(String(reflecting: processError))")
        } else if let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
          result = .standardOutput(output)
        } else if let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
          result = .standardError(error)
        } else {
          result = .failure("Uknown failure")
        }
      }
    }
  }
}
