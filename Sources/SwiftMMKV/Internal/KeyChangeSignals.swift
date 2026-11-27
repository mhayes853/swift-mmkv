/// Waits for changes to one key of a store, or to the keys under a prefix, for the async
/// sequences over them.
///
/// The first wait returns at once, so that a sequence starts with the value the store holds.
/// Changes that arrive between waits are folded into one, so a slow consumer only ever sees the
/// newest value.
struct KeyChangeSignals {
  private var iterator: AsyncStream<Void>.Iterator
  private let subscription: MMKVSubscription

  /// The keys whose changes are waited for.
  enum Keys: Sendable {
    case one(String)
    case under(String, separator: String)
  }

  init(store: MMKVStore, keys: Keys) {
    let (stream, continuation) = AsyncStream.makeStream(
      of: Void.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    // A closed store tells its listeners so once, and nothing after that.
    let onChange: @Sendable (MMKVStore.ChangeBatch) -> Void = { _ in
      continuation.yield()
      if store.isClosed {
        continuation.finish()
      }
    }
    self.subscription =
      switch keys {
      case .one(let key): store.subscribe(forKey: key, onChange)
      case .under(let prefix, let separator):
        store.subscribe(underKey: prefix, separator: separator, onChange)
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
