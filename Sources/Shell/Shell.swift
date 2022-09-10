import Foundation

public enum Shell {
  public static let defaultShellPath = "/bin/bash"

  public enum Result {
    case output(String)
    case error(String)
    case failure
  }
}

public protocol ShellExecutor {
  func `do`(_ command: String) async -> Shell.Result
  func sudo(_ command: String) async -> Shell.Result
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
    await shellProcess(command)
  }

  public func sudo(_ command: String) async -> Shell.Result {
    await shellProcess(command)
  }

  private func shellProcess(_ command: String) async -> Shell.Result {
    let process = Process()
    process.launchPath = shellPath
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    process.arguments = ["-c", command]
    process.launch()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return .failure }
    if let output = String(
      data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    ) {
      return .output(output)
    }
    if let error = String(
      data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    ) {
      return .error(error)
    }
    return .failure
  }
}
