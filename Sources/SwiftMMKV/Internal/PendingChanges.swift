/// Waits for changes to a store, for the async sequence over all of a store's changes.
///
/// Changes that arrive between waits are kept in the order they first arrived, and a change that
/// is already waiting is not added again. So a slow consumer misses no key, and holds at most
/// one change per key of the store.
struct PendingChanges {
  private let queue = Queue()
  private var wakeUps: AsyncStream<Void>.Iterator
  private let subscription: MMKVSubscription

  init(store: MMKVStore) {
    let (stream, continuation) = AsyncStream.makeStream(
      of: Void.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    // A closed store tells its listeners so once, and nothing after that.
    self.subscription = store.subscribe { [queue] change in
      queue.append(change)
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

  /// Waits for the next change.
  ///
  /// - Returns: `nil` if the task was cancelled instead.
  mutating func next() async -> MMKVStore.Change? {
    while !Task.isCancelled {
      if let change = self.queue.removeFirst() { return change }
      guard await self.wakeUps.next() != nil else { return nil }
    }
    return nil
  }

  @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
  mutating func next(isolation actor: isolated (any Actor)?) async -> MMKVStore.Change? {
    while !Task.isCancelled {
      if let change = self.queue.removeFirst() { return change }
      guard await self.wakeUps.next(isolation: actor) != nil else { return nil }
    }
    return nil
  }
}

extension PendingChanges {
  private final class Queue: Sendable {
    private struct State {
      var ordered = [MMKVStore.Change]()
      var waiting = Set<MMKVStore.Change>()
      /// The index of the first change in `ordered` that has not been taken.
      var head = 0
    }

    private let state = Lock(State())

    func append(_ change: MMKVStore.Change) {
      self.state.withLock { state in
        if state.waiting.insert(change).inserted { state.ordered.append(change) }
      }
    }

    func removeFirst() -> MMKVStore.Change? {
      self.state.withLock { state in
        guard state.head < state.ordered.count else { return nil }
        let change = state.ordered[state.head]
        state.head += 1
        state.waiting.remove(change)
        if state.head == state.ordered.count {
          state.ordered.removeAll(keepingCapacity: true)
          state.head = 0
        }
        return change
      }
    }
  }
}
