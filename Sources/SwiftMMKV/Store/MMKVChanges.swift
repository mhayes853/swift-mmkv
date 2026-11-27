// MARK: - Sequence

extension MMKVStore {
  /// What each operation changes in the store over time, as ``subscribe(_:)`` reports it.
  ///
  /// ```swift
  /// for await batch in store.changes {
  ///   if batch.isExternal { print("changed elsewhere") }
  ///   for key in batch.keys { print("changed:", key) }
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
  /// A consumer that falls behind misses no key, but receives the batches that are waiting as
  /// one: its ``ChangeBatch/keys`` holds every key they changed, each once and in the order it
  /// first changed, and it is external if any of them was.
  public var changes: MMKVChanges {
    MMKVChanges(store: self)
  }
}

// MARK: - MMKVChanges

/// What each operation changes in an ``MMKVStore`` over time, from ``MMKVStore/changes``.
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

    public mutating func next() async -> MMKVStore.ChangeBatch? {
      await self.pending.next()
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public mutating func next(
      isolation actor: isolated (any Actor)?
    ) async -> MMKVStore.ChangeBatch? {
      await self.pending.next(isolation: actor)
    }
  }
}
