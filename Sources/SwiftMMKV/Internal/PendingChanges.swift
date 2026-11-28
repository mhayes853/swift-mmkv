/// Waits for changes to a store, for the async sequence over all of a store's changes.
///
/// The batches that arrive between waits are merged by kind, as ``ChangeQueue`` merges them. So
/// a slow consumer misses no key, and holds at most two entries per key of the store.
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
      waiting.add(batch.kind)
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
    guard let kind = self.waiting.take() else { return nil }
    return MMKVStore.ChangeBatch(store: self.store, kind: kind)
  }
}

extension PendingChanges {
  private final class Waiting: Sendable {
    private let queue = Lock(ChangeQueue())

    func add(_ kind: MMKVStore.ChangeBatch.Kind) {
      self.queue.withLock { $0.add(kind) }
    }

    /// Removes and returns the batch that has waited longest.
    func take() -> MMKVStore.ChangeBatch.Kind? {
      self.queue.withLock { $0.removeFirst() }
    }
  }
}
