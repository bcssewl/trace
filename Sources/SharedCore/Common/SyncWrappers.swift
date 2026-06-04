import Foundation
import os.lock

/// Thread-safe boolean for sharing state across actor / non-actor boundaries.
///
/// Used in audio capture where IO procs run on real-time threads.
public final class SyncBool: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Bool>(initialState: false)

    public init(initial: Bool = false) {
        lock.withLock { $0 = initial }
    }

    public var value: Bool {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }

    /// Atomically swap if the current value equals `expected`.
    ///
    /// Returns true on swap.
    public func compareAndSwap(expected: Bool, desired: Bool) -> Bool {
        lock.withLock { current in
            guard current == expected else { return false }
            current = desired
            return true
        }
    }
}

/// Thread-safe string holder.
public final class SyncString: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<String>(initialState: "")

    public init(initial: String = "") {
        lock.withLock { $0 = initial }
    }

    public var value: String {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}

/// Thread-safe dictionary with read access and exclusive `update` block.
public final class SyncDict<K: Hashable & Sendable, V: Sendable>: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<[K: V]>

    public init(initial: [K: V] = [:]) {
        self.lock = .init(initialState: initial)
    }

    public var value: [K: V] {
        lock.withLock { $0 }
    }

    public func update(_ body: @Sendable (inout [K: V]) -> Void) {
        lock.withLock(body)
    }
}
