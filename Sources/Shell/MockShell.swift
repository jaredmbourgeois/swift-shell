import Foundation

public class MockShell: ShellExecutor {
  public typealias ActionHandler = (MockShell.Action) -> Void
  public private(set) var actions = [MockShell.Action]()
  public var lastAction: MockShell.Action? {
    actions.last
  }

  private let commandHandlers: [CommandHandler]
  private let actionHandler: ActionHandler?

  public init(
    _ commandHandlers: [CommandHandler],
    actionHandler: ActionHandler?
  ) {
    self.commandHandlers = commandHandlers
    self.actionHandler = actionHandler
  }

  public func clear() {
    actions = []
  }

  public func `do`(_ command: String) async -> Shell.Result {
    let result = commandHandlers.compactMap { $0.do(command) }.first ?? .failure
    handleAction(.do(command, result))
    return result
  }

  public func sudo(_ command: String, password: String) async -> Shell.Result {
    let result = commandHandlers.compactMap { $0.sudo(command, password: password) }.first ?? .failure
    handleAction(.sudo(command, password, result))
    return result
  }

  private func handleAction(_ action: MockShell.Action) {
    actions.append(action)
    actionHandler?(action)
  }
}

extension MockShell {
  public enum CommandHandler {
    case `do`(Do)
    case sudo(Sudo)
    case all(All)

    public typealias Do = (String) -> Shell.Result?
    public typealias Sudo = (String,String) -> Shell.Result?
    public typealias All = (String,String?) -> Shell.Result?

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
