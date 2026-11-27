/// Waits for changes to a store, for the async sequence over all of a store's changes.
///
/// The batches that arrive between waits are merged into one, which keeps each key once, in the
/// order it first changed. So a slow consumer misses no key, and holds at most one entry per
/// key of the store.
struct PendingChanges {
  private let store: MMKVStore
  private let waiting = Waiting()
  private var wakeUps: AsyncStream<Void>.Iterator
  private let subscription: MMKVSubscription

  init(store: MMKVStore) {
    let (stream, continuation) = AsyncStream.makeStream(
      of: Void.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    self.store = store
    // A closed store tells its listeners so once, and nothing after that.
    self.subscription = store.subscribe { [waiting] batch in
      waiting.add(keys: batch.keys, isExternal: batch.isExternal)
      continuation.yield()
      if store.isClosed {
        continuation.finish()
      }
    }
    if store.isClosed {
      continuation.finish()
    }
    self.wakeUps = stream.makeAsyncIterator()
  }

  /// Waits for the next batch of changes.
  ///
  /// - Returns: `nil` if the task was cancelled instead.
  mutating func next() async -> MMKVStore.ChangeBatch? {
    while !Task.isCancelled {
      if let batch = self.takeWaiting() { return batch }
      guard await self.wakeUps.next() != nil else { return self.takeWaiting() }
    }
    return nil
  }

  @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
  mutating func next(isolation actor: isolated (any Actor)?) async -> MMKVStore.ChangeBatch? {
    while !Task.isCancelled {
      if let batch = self.takeWaiting() { return batch }
      guard await self.wakeUps.next(isolation: actor) != nil else { return self.takeWaiting() }
    }
    return nil
  }

  private func takeWaiting() -> MMKVStore.ChangeBatch? {
    let changes = self.waiting.take()
    guard !changes.isEmpty else { return nil }
    return MMKVStore.ChangeBatch(
      store: self.store,
      keys: changes.keys,
      isExternal: changes.isExternal
    )
  }
}

extension PendingChanges {
  private final class Waiting: Sendable {
    private struct State {
      var changes = StoreChanges(keys: [], isExternal: false)
      /// The keys of `changes`, for telling whether a key is already among them.
      var keys = Set<String>()
    }

    private let state = Lock(State())

    func add(keys: [String], isExternal: Bool) {
      self.state.withLock { state in
        for key in keys where state.keys.insert(key).inserted {
          state.changes.keys.append(key)
        }
        state.changes.isExternal = state.changes.isExternal || isExternal
      }
    }

    /// Removes and returns everything that is waiting.
    func take() -> StoreChanges {
      self.state.withLock { state in
        defer { state = State() }
        return state.changes
      }
    }
  }
}
