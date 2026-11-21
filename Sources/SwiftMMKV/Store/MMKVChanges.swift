// MARK: - Sequence

extension MMKVStore {
  /// The changes to the store's contents over time, as ``subscribe(_:)`` reports them.
  ///
  /// ```swift
  /// for await change in store.changes {
  ///   switch change {
  ///   case .key(let key): print("changed:", key)
  ///   case .external: print("changed elsewhere")
  ///   }
  /// }
  /// ```
  ///
  /// The sequence produces the changes made after iteration begins, and nothing for the
  /// contents the store already has. It never finishes on its own. It ends when the task
  /// iterating it is cancelled.
  ///
  /// Each iteration observes the store separately, so the sequence can be iterated more than
  /// once, and by several tasks at a time.
  ///
  /// ## Falling behind
  ///
  /// A consumer that falls behind misses no key, but receives each waiting change once: a key
  /// written several times in the meantime is produced once, and so are several
  /// ``Change/external`` changes. Changes are produced in the order they first arrived.
  public var changes: MMKVChanges {
    MMKVChanges(store: self)
  }
}

// MARK: - MMKVChanges

/// The changes to an ``MMKVStore`` over time, from ``MMKVStore/changes``.
public struct MMKVChanges: AsyncSequence, Sendable {
  private let store: MMKVStore

  fileprivate init(store: MMKVStore) {
    self.store = store
  }

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(store: self.store)
  }

  public struct AsyncIterator: AsyncIteratorProtocol {
    private var pending: PendingChanges

    fileprivate init(store: MMKVStore) {
      self.pending = PendingChanges(store: store)
    }

    public mutating func next() async -> MMKVStore.Change? {
      await self.pending.next()
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public mutating func next(isolation actor: isolated (any Actor)?) async -> MMKVStore.Change? {
      await self.pending.next(isolation: actor)
    }
  }
}
