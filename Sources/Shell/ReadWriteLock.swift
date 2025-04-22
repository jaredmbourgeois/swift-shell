// ReadWriteLock.swift is part of the swift-shell open source project.
//
// Copyright © 2025 Jared Bourgeois
//
// Licensed under Apache License v2.0 with Runtime Library Exception
//

import Foundation

public final class ReadWriteLock<Value>: @unchecked Sendable {
    private var lock = pthread_rwlock_t()
    private var _value: Value
    public var value: Value {
        get {
            pthread_rwlock_rdlock(&lock)
            let value = _value
            pthread_rwlock_unlock(&lock)
            return value
        }
        set {
            pthread_rwlock_wrlock(&lock)
            _value = newValue
            pthread_rwlock_unlock(&lock)
        }
    }

    public init(_ value: Value) {
        guard pthread_rwlock_init(&lock, nil) == 0 else {
            fatalError("pthread_rwlock_init failed")
        }
        self._value = value
    }

    deinit {
        pthread_rwlock_destroy(&lock)
    }

    @discardableResult
    public func reading<T>(_ read: (inout Value) throws -> T) rethrows -> T {
        pthread_rwlock_rdlock(&lock)
        defer { pthread_rwlock_unlock(&lock) }
        return try read(&_value)
    }

    @discardableResult
    public func writing<T>(_ read: (inout Value) throws -> T) rethrows -> T {
        pthread_rwlock_wrlock(&lock)
        defer { pthread_rwlock_unlock(&lock) }
        return try read(&_value)
    }
}
