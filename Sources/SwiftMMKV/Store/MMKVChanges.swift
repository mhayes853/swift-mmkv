// MARK: - Sequence

extension MMKVStore {
  /// The changes to the store over time, as ``subscribe(_:)`` reports them.
  ///
  /// ```swift
  /// for await batch in store.changes {
  ///   switch batch.kind {
  ///   case .localKeys(let keys): print("changed here:", keys)
  ///   case .externalKeys(let keys): print("changed elsewhere:", keys)
  ///   case .wholeStore(let reason): print("anything may have changed:", reason.rawValue)
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
  /// A consumer that falls behind misses no key, but receives the batches that are waiting
  /// merged by kind: one ``ChangeBatch/Kind/localKeys(_:)`` batch with every local key, one
  /// ``ChangeBatch/Kind/externalKeys(_:)`` batch with every external key, each key once and in
  /// the order it first changed, and one ``ChangeBatch/Kind/wholeStore(_:)`` batch for each
  /// reason. A waiting whole-store batch takes the place of waiting external keys, since it
  /// already says any key may have changed. Local keys are always delivered. The merged batches
  /// arrive in the order the first of each did.
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
