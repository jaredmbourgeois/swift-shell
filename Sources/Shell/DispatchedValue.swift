import Dispatch
import Foundation

public class DispatchedValue<ValueType: Any> {
  private let valueSemaphore = DispatchSemaphore(value: 1)
  private var _value: ValueType
  public var value: ValueType {
    get {
      valueSemaphore.wait()
      let value = _value
      valueSemaphore.signal()
      return value
    }
    set {
      valueSemaphore.wait()
      _value = newValue
      valueSemaphore.signal()
    }
  }

  public init(_ value: ValueType) {
    _value = value
  }
}

