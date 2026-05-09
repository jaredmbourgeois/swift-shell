// ReadWriteLock.swift is part of the swift-shell open source project.
//
// Copyright © 2025 Jared Bourgeois
//
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// Backed by `NSLock` rather than `pthread_rwlock_t`. Cross-platform (Linux via
// swift-corelibs-foundation, macOS native), no pthread C-interop, no separate
// reader/writer modes — the consumers of this type only ever call `writing`.
// `OSAllocatedUnfairLock` would be Apple-only and explicitly drops fairness, so
// it's not a fit for a cross-platform shell library.

import Foundation

public final class ReadWriteLock<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    public var value: Value {
        get { writing { $0 } }
        set { writing { $0 = newValue } }
    }

    public init(_ value: Value) {
        self._value = value
    }

    @discardableResult
    public func reading<T>(_ read: (inout Value) throws -> T) rethrows -> T {
        try writing(read)
    }

    @discardableResult
    public func writing<T>(_ operation: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation(&_value)
    }
}
