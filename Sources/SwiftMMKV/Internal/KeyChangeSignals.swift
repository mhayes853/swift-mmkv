/// Waits for changes to one key of a store, for the async sequences over a key.
///
/// The first wait returns at once, so that a sequence starts with the value the store holds.
/// Changes that arrive between waits are folded into one, so a slow consumer only ever sees the
/// newest value.
struct KeyChangeSignals {
  private var iterator: AsyncStream<Void>.Iterator
  private let subscription: MMKVSubscription

  init(store: MMKVStore, key: String) {
    let (stream, continuation) = AsyncStream.makeStream(
      of: Void.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    // A closed store tells its listeners so once, and nothing after that.
    self.subscription = store.subscribe(forKey: key) {
      continuation.yield()
      if store.isClosed {
        continuation.finish()
      }
    }
    continuation.yield()
    if store.isClosed {
      continuation.finish()
    }
    self.iterator = stream.makeAsyncIterator()
  }

  /// Waits for the next change.
  ///
  /// - Returns: `false` if the task was cancelled instead.
  mutating func next() async -> Bool {
    await self.iterator.next() != nil
  }

  @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
  mutating func next(isolation actor: isolated (any Actor)?) async -> Bool {
    await self.iterator.next(isolation: actor) != nil
  }
}
