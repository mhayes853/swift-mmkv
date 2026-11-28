// MARK: - Several Keys

extension MMKVStore {
  /// Calls `onChange` with the values of `keys`, once before this function returns and then
  /// once for each operation that may have changed any of them, until the returned
  /// subscription is cancelled or released.
  ///
  /// ```swift
  /// let subscription = store.subscribe(forKeys: ["width", "height"], as: Double.self) { size in
  ///   resize(width: size["width"] ?? 0, height: size["height"] ?? 0)
  /// }
  /// ```
  ///
  /// The values are read together, as ``values(forKeys:as:)`` reads them, so a key is left out
  /// when it has no value or its value is not a valid `V`. An operation that changes several of
  /// the keys, such as ``set(_:expiry:)`` or the body of a ``withExclusiveLock(_:)``, runs
  /// `onChange` once, after all of them are written.
  ///
  /// `onChange` may be given the values it was last given: it runs whenever one of the keys is
  /// written, here or in another process, and for every whole-store change, which does not say
  /// which keys it touched. In other respects this behaves like ``subscribe(_:)``.
  ///
  /// - Parameters:
  ///   - keys: The keys to observe.
  ///   - type: The type to read each value as.
  ///   - onChange: Runs with the current values, and again after each such operation.
  public func subscribe<V: MMKVValue & SendableMetatype>(
    forKeys keys: [String],
    as type: V.Type = V.self,
    _ onChange: @escaping @Sendable ([String: V]) -> Void
  ) -> MMKVSubscription {
    self.subscribe(toAnyOf: Set(keys)) {
      onChange(self.values(forKeys: keys, as: V.self))
    }
  }

  /// Calls `onChange` with the `Decodable` values of `keys`, each read with `decoder`, once
  /// before this function returns and then once for each operation that may have changed any
  /// of them, until the returned subscription is cancelled or released.
  ///
  /// ```swift
  /// let subscription = store.subscribe(
  ///   forKeys: ["home", "work"],
  ///   as: Address.self,
  ///   with: decoder
  /// ) { addresses in
  ///   home = try? addresses["home"]?.get()
  /// }
  /// ```
  ///
  /// Each key has a result of its own, so a value that does not decode does not hide the
  /// others. A key is left out when the store has no value for it. Its result is a failure with
  /// whatever `decoder` throws when its value does not decode, and with
  /// ``MMKVError/Code/storeIsSuspended`` while the store is suspended. The subscription carries
  /// on after a failure.
  ///
  /// In other respects this behaves like ``subscribe(forKeys:as:_:)``, including reading the
  /// values together and running with values it was already given.
  ///
  /// - Parameters:
  ///   - keys: The keys to observe.
  ///   - type: The type to decode each value as.
  ///   - decoder: The decoder that reads each value.
  ///   - onChange: Runs with the current values, and again after each such operation.
  public func subscribe<T: Decodable & SendableMetatype, Decoder: MMKVTopLevelDecoder & Sendable>(
    forKeys keys: [String],
    as type: T.Type = T.self,
    with decoder: Decoder,
    _ onChange: @escaping @Sendable ([String: Result<T, any Error>]) -> Void
  ) -> MMKVSubscription where Decoder.Input: MMKVValue {
    self.subscribe(toAnyOf: Set(keys)) {
      let results = self.withExclusiveLock { store in
        var results = [String: Result<T, any Error>]()
        for key in keys {
          do {
            results[key] = try store.decode(T.self, forKey: key, with: decoder).map(Result.success)
          } catch {
            results[key] = .failure(error)
          }
        }
        return results
      }
      onChange(results)
    }
  }
}

// MARK: - Several Typed Keys

extension MMKVStore {
  /// Calls `onChange` with the values of two or more keys, once before this function returns
  /// and then once for each operation that may have changed any of them, until the returned
  /// subscription is cancelled or released.
  ///
  /// ```swift
  /// let subscription = store.subscribe(for: .username, .avatarURL) { username, avatarURL in
  ///   header.show(username: username, avatarURL: avatarURL)
  /// }
  /// ```
  ///
  /// The values are read together, so they are never those of an operation that is half done.
  /// An operation that changes several of the keys, such as ``set(_:expiry:)-(_,MMKVExpiry?)``
  /// or the body of a ``withExclusiveLock(_:)``, runs `onChange` once, after all of them are
  /// written.
  ///
  /// The keys are all of one kind. To follow keys of different kinds together, read them from
  /// the batch that ``subscribe(_:)`` gives. In other respects this behaves like
  /// ``subscribe(for:_:)-(Key<V>,_)``, including running with values it was already given.
  ///
  /// - Parameters:
  ///   - first: The first key to observe.
  ///   - second: The second key to observe.
  ///   - others: Any further keys to observe.
  ///   - onChange: Runs with the current values, in the order of the keys, and again after
  ///     each such operation.
  public func subscribe<V1: SendableMetatype, V2: SendableMetatype, each V: SendableMetatype>(
    for first: Key<V1>,
    _ second: Key<V2>,
    _ others: repeat Key<each V>,
    onChange: @escaping @Sendable (V1?, V2?, repeat (each V)?) -> Void
  ) -> MMKVSubscription {
    var names: Set = [first.name, second.name]
    for key in repeat each others {
      names.insert(key.name)
    }
    return self.subscribe(toAnyOf: names) {
      let values = self.withExclusiveLock { store in
        (store.value(for: first), store.value(for: second), (repeat store.value(for: each others)))
      }
      onChange(values.0, values.1, repeat each values.2)
    }
  }

  /// Calls `onChange` with the values of several keys, or their defaults, once before this
  /// function returns and then once for each operation that may have changed any of them,
  /// until the returned subscription is cancelled or released.
  ///
  /// ```swift
  /// let subscription = store.subscribe(for: .volume, .brightness) { volume, brightness in
  ///   apply(volume: volume, brightness: brightness)
  /// }
  /// ```
  ///
  /// A value is its key's default whenever the store has no value for the key. In other
  /// respects this behaves like ``subscribe(for:_:)-(Key<V>,_)`` over several keys.
  ///
  /// - Parameters:
  ///   - first: The first key to observe.
  ///   - second: The second key to observe.
  ///   - others: Any further keys to observe.
  ///   - onChange: Runs with the current values, in the order of the keys, and again after
  ///     each such operation.
  public func subscribe<V1: SendableMetatype, V2: SendableMetatype, each V: SendableMetatype>(
    for first: DefaultedKey<V1>,
    _ second: DefaultedKey<V2>,
    _ others: repeat DefaultedKey<each V>,
    onChange: @escaping @Sendable (V1, V2, repeat each V) -> Void
  ) -> MMKVSubscription {
    var names: Set = [first.key.name, second.key.name]
    for key in repeat each others {
      names.insert(key.key.name)
    }
    return self.subscribe(toAnyOf: names) {
      let values = self.withExclusiveLock { store in
        (store.value(for: first), store.value(for: second), (repeat store.value(for: each others)))
      }
      onChange(values.0, values.1, repeat each values.2)
    }
  }

  /// Calls `onChange` with the decoded values of several keys, once before this function
  /// returns and then once for each operation that may have changed any of them, until the
  /// returned subscription is cancelled or released.
  ///
  /// ```swift
  /// let subscription = store.subscribe(for: .settings, .profile) { settings, profile in
  ///   apply((try? settings.get()) ?? Settings(), (try? profile.get()) ?? Profile())
  /// }
  /// ```
  ///
  /// Each key has a result of its own, as ``subscribe(for:_:)-(CodedKey<V>,_)`` gives it, so a
  /// value that does not decode does not hide the others. In other respects this behaves like
  /// ``subscribe(for:_:)-(Key<V>,_)`` over several keys, including reading the values together.
  ///
  /// - Parameters:
  ///   - first: The first key to observe.
  ///   - second: The second key to observe.
  ///   - others: Any further keys to observe.
  ///   - onChange: Runs with the current values, in the order of the keys, and again after
  ///     each such operation.
  public func subscribe<V1: SendableMetatype, V2: SendableMetatype, each V: SendableMetatype>(
    for first: CodedKey<V1>,
    _ second: CodedKey<V2>,
    _ others: repeat CodedKey<each V>,
    onChange:
      @escaping @Sendable (
        Result<V1?, any Error>, Result<V2?, any Error>, repeat Result<(each V)?, any Error>
      ) -> Void
  ) -> MMKVSubscription {
    var names: Set = [first.name, second.name]
    for key in repeat each others {
      names.insert(key.name)
    }
    return self.subscribe(toAnyOf: names) {
      func read<T>(_ key: CodedKey<T>, from store: MMKVStore) -> Result<T?, any Error> {
        Result { try store.value(for: key) }
      }
      let results = self.withExclusiveLock { store in
        (
          read(first, from: store), read(second, from: store),
          (repeat read(each others, from: store))
        )
      }
      onChange(results.0, results.1, repeat each results.2)
    }
  }

  /// Calls `onChange` with the decoded values of several keys, or their defaults, once before
  /// this function returns and then once for each operation that may have changed any of them,
  /// until the returned subscription is cancelled or released.
  ///
  /// A result is a success of its key's default whenever the store has no value for the key.
  /// In other respects this behaves like ``subscribe(for:_:)-(CodedKey<V>,_)`` over several
  /// keys.
  ///
  /// - Parameters:
  ///   - first: The first key to observe.
  ///   - second: The second key to observe.
  ///   - others: Any further keys to observe.
  ///   - onChange: Runs with the current values, in the order of the keys, and again after
  ///     each such operation.
  public func subscribe<V1: SendableMetatype, V2: SendableMetatype, each V: SendableMetatype>(
    for first: DefaultedCodedKey<V1>,
    _ second: DefaultedCodedKey<V2>,
    _ others: repeat DefaultedCodedKey<each V>,
    onChange:
      @escaping @Sendable (
        Result<V1, any Error>, Result<V2, any Error>, repeat Result<each V, any Error>
      ) -> Void
  ) -> MMKVSubscription {
    var names: Set = [first.key.name, second.key.name]
    for key in repeat each others {
      names.insert(key.key.name)
    }
    return self.subscribe(toAnyOf: names) {
      func read<T>(_ key: DefaultedCodedKey<T>, from store: MMKVStore) -> Result<T, any Error> {
        Result { try store.value(for: key) }
      }
      let results = self.withExclusiveLock { store in
        (
          read(first, from: store), read(second, from: store),
          (repeat read(each others, from: store))
        )
      }
      onChange(results.0, results.1, repeat each results.2)
    }
  }
}

// MARK: - Helpers

extension MMKVStore {
  /// Runs `onChange` now, and again after each operation that may have changed any of `names`.
  private func subscribe(
    toAnyOf names: Set<String>,
    _ onChange: @escaping @Sendable () -> Void
  ) -> MMKVSubscription {
    let subscription = self.subscribe { batch in
      if batch.kind.hasChangeCandidate(where: names.contains) {
        onChange()
      }
    }
    onChange()
    return subscription
  }
}
