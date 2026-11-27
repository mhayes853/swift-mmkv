/// Produces the values of one key of a store, or of the keys under a prefix, over time, for the
/// async sequences over them.
///
/// The first wait returns at once, so that a sequence starts with the value the store holds.
/// Changes that arrive between waits are folded into one, so a slow consumer only ever sees the
/// newest value.
struct KeyValueIterator {
  private let store: MMKVStore
  private var changes: AsyncStream<Void>.Iterator
  private let subscription: MMKVSubscription
  private var isFinished = false

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
    self.store = store
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
    self.changes = stream.makeAsyncIterator()
  }

  /// Waits for changes until `read` produces an element. `read` returns `nil` to skip a change,
  /// as it does when the store is suspended and turns the read away: resuming the store signals
  /// a change, which reads the element again. An error `read` throws ends the iteration.
  ///
  /// - Returns: `nil` once the task is cancelled or an error has ended the iteration.
  mutating func next<Element, E: Error>(
    _ read: (MMKVStore) throws(E) -> Element?
  ) async throws(E) -> Element? {
    while !self.isFinished, await self.changes.next() != nil {
      if let element = try self.element(read) { return element }
    }
    return nil
  }

  @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
  mutating func next<Element, E: Error>(
    isolation actor: isolated (any Actor)?,
    _ read: (MMKVStore) throws(E) -> Element?
  ) async throws(E) -> Element? {
    while !self.isFinished, await self.changes.next(isolation: actor) != nil {
      if let element = try self.element(read) { return element }
    }
    return nil
  }

  private mutating func element<Element, E: Error>(
    _ read: (MMKVStore) throws(E) -> Element?
  ) throws(E) -> Element? {
    do {
      return try read(self.store)
    } catch {
      self.isFinished = true
      throw error
    }
  }
}
