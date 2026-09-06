/// A property written on one thread and read on others: the keyboard event taps read a few
/// preference values off the main thread. Every access takes an unfair lock; readers get a copy.

import os

@propertyWrapper
struct ThreadSafe<Value> {
    private let storage: OSAllocatedUnfairLock<Value>

    init(wrappedValue: Value) {
        storage = OSAllocatedUnfairLock(uncheckedState: wrappedValue)
    }

    var wrappedValue: Value {
        get { storage.withLockUnchecked { $0 } }
        nonmutating set { storage.withLockUnchecked { $0 = newValue } }
    }
}
