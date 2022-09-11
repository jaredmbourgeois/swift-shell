import Foundation

public enum Shell {
  public static let defaultShellPath = "/bin/bash"

  public enum Result {
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

public protocol ShellExecutor {
  func `do`(_ command: String) async -> Shell.Result
  func doSynchronously(_ command: String) -> Shell.Result
  func sudo(_ command: String) async -> Shell.Result
  func sudoSynchronously(_ command: String) -> Shell.Result
}

extension Shell {
  public actor Executor: ShellExecutor {
    public nonisolated let shellPath: String

    public init(shellPath: String = Shell.defaultShellPath) {
      self.shellPath = shellPath
    }
  }
}

extension Shell.Executor {
  public func `do`(_ command: String) async -> Shell.Result {
    shellProcess(command)
  }

  nonisolated public func doSynchronously(_ command: String) -> Shell.Result {
    shellProcess(command)
  }


  public func sudo(_ command: String) async -> Shell.Result {
    shellProcess(command)
  }

  nonisolated public func sudoSynchronously(_ command: String) -> Shell.Result {
    shellProcess(command)
  }

  nonisolated
  private func shellProcess(_ command: String) -> Shell.Result {
    var result: Shell.Result = .failure
    let shellUrl = URL(fileURLWithPath: shellPath)
    let process = Process()
    process.executableURL = shellUrl
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    process.arguments = ["-c", command]
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      result = .error(error.localizedDescription)
    }
    guard process.terminationStatus == 0 else { return .failure }
    if let output = String(
      data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    ) {
      result = .output(output)
    }
    if let error = String(
      data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    ) {
      result = .error(error)
    }
    print("swift-shell\n\tcommand: \(command)\n\tresult: \(result.description)")
    return result
  }
}
