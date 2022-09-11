import Foundation

public class MockShell: ShellExecutor {
  public typealias ActionHandler = (MockShell.Action) -> Void
  private var _actions = DispatchedValue<[MockShell.Action]>([])
  public var actions: [MockShell.Action] {
    _actions.value
  }
  public var lastAction: MockShell.Action? {
    _actions.value.last
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
    _actions.value = []
  }

  public func `do`(_ command: String) async -> Shell.Result {
    let result = commandHandlers.compactMap { $0.do(command) }.first ?? .failure
    handleAction(.do(command, result))
    return result
  }

  public func doSynchronously(_ command: String) -> Shell.Result {
    let result = commandHandlers.compactMap { $0.do(command) }.first ?? .failure
    handleAction(.do(command, result))
    return result
  }

  public func sudo(_ command: String) async -> Shell.Result {
    let result = commandHandlers.compactMap { $0.sudo(command) }.first ?? .failure
    handleAction(.sudo(command, result))
    return result
  }

  public func sudoSynchronously(_ command: String) -> Shell.Result {
    let result = commandHandlers.compactMap { $0.sudo(command) }.first ?? .failure
    handleAction(.sudo(command, result))
    return result
  }

  private func handleAction(_ action: MockShell.Action) {
    _actions.value.append(action)
    actionHandler?(action)
  }
}

extension MockShell {
  public enum CommandHandler {
    case `do`(Do)
    case sudo(Sudo)
    case all(All)

    public typealias Do = (String) -> Shell.Result?
    public typealias Sudo = (String) -> Shell.Result?
    public typealias All = (String) -> Shell.Result?

    public func `do`(_ command: String) -> Shell.Result? {
      switch self {
      case .`do`(let handler): return handler(command)
      case .sudo: return nil
      case .all(let handler): return handler(command)
      }
    }

    public func sudo(_ command: String) -> Shell.Result? {
      switch self {
      case .`do`: return nil
      case .sudo(let handler): return handler(command)
      case .all(let handler): return handler(command)
      }
    }
  }
}

extension MockShell {
  public enum Action {
    case `do`(String,Shell.Result)
    case sudo(String,Shell.Result)

    public var command: String {
      switch self {
      case .`do`(let command, _): return command
      case .sudo(let command, _): return command
      }
    }

    public var result: Shell.Result {
      switch self {
      case .`do`(_, let result): return result
      case .sudo(_, let result): return result
      }
    }
  }
}
