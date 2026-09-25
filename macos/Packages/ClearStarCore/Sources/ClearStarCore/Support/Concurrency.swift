import Foundation
import Synchronization

/// Cooperative cancellation shared by the steps – the counterpart of the C# CancellationToken.
public final class CancellationToken: Sendable {
    private let flag = Atomic<Bool>(false)

    public init() {}

    /// A token that is never cancelled.
    public static let none = CancellationToken()

    public var isCancelled: Bool { flag.load(ordering: .relaxed) }
    public func cancel() { flag.store(true, ordering: .relaxed) }

    public func check() throws {
        if isCancelled { throw CancellationError() }
    }
}

/// Runs `body` for 0..<count on all cores (the C# Parallel.For).
@inline(__always)
func parallelFor(_ count: Int, _ body: (Int) -> Void) {
    if count <= 0 { return }
    if count == 1 { body(0); return }
    DispatchQueue.concurrentPerform(iterations: count, execute: body)
}

/// Like `parallelFor`, but stops early (and throws) once the token is cancelled.
func parallelFor(_ count: Int, _ ct: CancellationToken, _ body: (Int) -> Void) throws {
    try ct.check()
    parallelFor(count) { i in
        if ct.isCancelled { return }
        body(i)
    }
    try ct.check()
}

/// A lock-protected value for the few pieces of shared mutable state (caches, "last result" fields).
public final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    public init(_ value: Value) { self.value = value }

    public func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    public var current: Value {
        get { withLock { $0 } }
        set { withLock { $0 = newValue } }
    }
}

/// Error with a user-facing message (the C# InvalidOperationException with a localised text).
public struct ClearStarError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
