import Foundation

public class MockShell: ShellExecutor {
  public private(set) var actions = [MockShell.Action]()
  public var lastAction: MockShell.Action? {
    actions.last
  }

  private let handlers: [CommandHandler]

  public init(_ handlers: [CommandHandler]) {
    self.handlers = handlers
  }

  public func clear() {
    actions = []
  }

  public func `do`(_ command: String) async -> Shell.Result {
    let result = handlers.compactMap { $0.do(command) }.first ?? .failure
    actions.append(.do(command, result))
    return result
  }

  public func sudo(_ command: String, password: String) async -> Shell.Result {
    let result = handlers.compactMap { $0.sudo(command, password: password) }.first ?? .failure
    actions.append(.sudo(command, password, result))
    return result
  }
}

extension MockShell {
  public enum CommandHandler {
    case `do`(ResultForDo)
    case sudo(ResultForSudo)
    case all(ResultForAll)

    public func `do`(_ command: String) -> Shell.Result? {
      switch self {
      case .`do`(let handler): return handler(command)
      case .sudo: return nil
      case .all(let handler): return handler(command, nil)
      }
    }

    public func sudo(_ command: String, password: String) -> Shell.Result? {
      switch self {
      case .`do`: return nil
      case .sudo(let handler): return handler(command, password)
      case .all(let handler): return handler(command, password)
      }
    }
  }
  public typealias ResultForDo = (String) -> Shell.Result?
  public typealias ResultForSudo = (String,String) -> Shell.Result?
  public typealias ResultForAll = (String,String?) -> Shell.Result?
}

extension MockShell {
  public enum Action {
    case `do`(String,Shell.Result)
    case sudo(String,String,Shell.Result)

    public var command: String {
      switch self {
      case .`do`(let command, _): return command
      case .sudo(let command, _, _): return command
      }
    }

    public var password: String? {
      switch self {
      case .`do`: return nil
      case .sudo(_, let password, _): return password
      }
    }

    public var result: Shell.Result {
      switch self {
      case .`do`(_, let result): return result
      case .sudo(_, _, let result): return result
      }
    }
  }
}
