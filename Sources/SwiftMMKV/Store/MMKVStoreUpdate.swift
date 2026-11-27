// MARK: - String Keys

extension MMKVStore {
  /// Reads the value of `key`, lets `body` change it, and writes the result, with no other
  /// thread or process able to write to the store in between.
  ///
  /// ```swift
  /// store.update(forKey: "launchCount", as: Int.self) { $0 = ($0 ?? 0) + 1 }
  /// ```
  ///
  /// `body` is given `nil` when the store has no value for `key`, or when its value is not a
  /// valid `V`. Setting the value to `nil` removes the key, and a value that was `nil` and is
  /// left `nil` leaves the store alone.
  ///
  /// The store is locked as ``withExclusiveLock(_:)`` locks it, so `body` may read and write
  /// the store, and must not wait for another thread that uses it. Listeners are told about
  /// the key once `body` has returned and the result is written.
  ///
  /// The result is written even when `body` did not change the value. The write gives the key
  /// `expiry`, or the store's default, whatever expiry it had before.
  ///
  /// - Parameters:
  ///   - key: The key to update.
  ///   - type: The type to read and write the value as.
  ///   - expiry: How long to keep the value. See ``set(_:forKey:expiry:)``.
  ///   - body: Changes the value in place. If it throws, nothing is written.
  /// - Returns: Whether the store accepted the write or removal. A store that is suspended or
  ///   closed accepts nothing, and `body` is not run for one.
  @discardableResult
  public func update<V: MMKVValue, E: Error>(
    forKey key: String,
    as type: V.Type = V.self,
    expiry: MMKVExpiry? = nil,
    _ body: (inout V?) throws(E) -> Void
  ) throws(E) -> Bool {
    try self.withExclusiveLock { (store) throws(E) -> Bool in
      guard MMKVErrors.unavailable(store) == nil else { return false }
      var value = store.value(forKey: key, as: V.self)
      let hadValue = value != nil
      try body(&value)
      guard let value else {
        return hadValue ? store.removeValue(forKey: key) : true
      }
      return store.set(value, forKey: key, expiry: expiry)
    }
  }

  /// Reads the `Codable` value of `key` with `decoder`, lets `body` change it, and writes the
  /// result with `encoder`, with no other thread or process able to write to the store in
  /// between.
  ///
  /// ```swift
  /// try store.update(
  ///   forKey: "settings",
  ///   as: Settings.self,
  ///   encoder: JSONEncoder(),
  ///   decoder: JSONDecoder()
  /// ) { settings in
  ///   settings?.theme = .dark
  /// }
  /// ```
  ///
  /// `body` is given `nil` when the store has no value for `key`. In other respects this
  /// behaves like ``update(forKey:as:expiry:_:)``.
  ///
  /// - Parameters:
  ///   - key: The key to update.
  ///   - type: The type to decode and encode.
  ///   - encoder: The encoder that writes the value.
  ///   - decoder: The decoder that reads the value.
  ///   - expiry: How long to keep the value. See ``set(_:forKey:expiry:)``.
  ///   - body: Changes the value in place. If it throws, nothing is written.
  /// - Returns: Whether the store accepted the write or removal.
  /// - Throws: Whatever `decoder` throws when the stored value does not decode, in which case
  ///   `body` is not run. Whatever `body` or `encoder` throws, in which case nothing is
  ///   written. ``MMKVError/Code/storeIsSuspended`` or ``MMKVError/Code/storeIsClosed`` if the
  ///   store is suspended or closed, without `body` being run.
  @discardableResult
  public func update<T: Codable, Encoder: MMKVTopLevelEncoder, Decoder: MMKVTopLevelDecoder>(
    forKey key: String,
    as type: T.Type = T.self,
    encoder: Encoder,
    decoder: Decoder,
    expiry: MMKVExpiry? = nil,
    _ body: (inout T?) throws -> Void
  ) throws -> Bool where Encoder.Output: MMKVValue, Decoder.Input: MMKVValue {
    try self.withExclusiveLock { store in
      if let error = MMKVErrors.unavailable(store) {
        throw error
      }
      var value = try store.decode(T.self, forKey: key, with: decoder)
      let hadValue = value != nil
      try body(&value)
      guard let value else {
        return hadValue ? store.removeValue(forKey: key) : true
      }
      return try store.encode(value, forKey: key, expiry: expiry, with: encoder)
    }
  }
}

// MARK: - Typed Keys

extension MMKVStore {
  /// Reads the value of `key`, lets `body` change it, and writes the result, with no other
  /// thread or process able to write to the store in between.
  ///
  /// ```swift
  /// store.update(for: .username) { $0 = $0?.lowercased() }
  /// ```
  ///
  /// This behaves like ``update(forKey:as:expiry:_:)``.
  @discardableResult
  public func update<V, E: Error>(
    for key: Key<V>,
    expiry: MMKVExpiry? = nil,
    _ body: (inout V?) throws(E) -> Void
  ) throws(E) -> Bool {
    try self.update(forKey: key.name, as: V.self, expiry: expiry, body)
  }

  /// Reads the value of `key`, lets `body` change it, and writes the result, with no other
  /// thread or process able to write to the store in between.
  ///
  /// ```swift
  /// store.update(for: .launchCount) { $0 += 1 }
  /// ```
  ///
  /// `body` is given the key's default when the store has no value for the key, and the result
  /// is written even when it equals the default. In other respects this behaves like
  /// ``update(forKey:as:expiry:_:)``.
  @discardableResult
  public func update<V, E: Error>(
    for key: DefaultedKey<V>,
    expiry: MMKVExpiry? = nil,
    _ body: (inout V) throws(E) -> Void
  ) throws(E) -> Bool {
    try self.withExclusiveLock { (store) throws(E) -> Bool in
      guard MMKVErrors.unavailable(store) == nil else { return false }
      var value = store.value(for: key)
      try body(&value)
      return store.set(value, for: key, expiry: expiry)
    }
  }

  /// Reads and decodes the value of `key`, lets `body` change it, and encodes and writes the
  /// result, with no other thread or process able to write to the store in between.
  ///
  /// ```swift
  /// try store.update(for: .settings) { $0?.theme = .dark }
  /// ```
  ///
  /// This behaves like ``update(forKey:as:encoder:decoder:expiry:_:)``, with the key's coders.
  @discardableResult
  public func update<V>(
    for key: CodedKey<V>,
    expiry: MMKVExpiry? = nil,
    _ body: (inout V?) throws -> Void
  ) throws -> Bool {
    try self.withExclusiveLock { store in
      if let error = MMKVErrors.unavailable(store) {
        throw error
      }
      var value = try store.value(for: key)
      let hadValue = value != nil
      try body(&value)
      guard let value else {
        return hadValue ? store.removeValue(for: key) : true
      }
      return try store.set(value, for: key, expiry: expiry)
    }
  }

  /// Reads and decodes the value of `key`, lets `body` change it, and encodes and writes the
  /// result, with no other thread or process able to write to the store in between.
  ///
  /// ```swift
  /// try store.update(for: .settings) { $0.theme = .dark }
  /// ```
  ///
  /// `body` is given the key's default when the store has no value for the key, and the result
  /// is written even when it equals the default. In other respects this behaves like
  /// ``update(forKey:as:encoder:decoder:expiry:_:)``, with the key's coders.
  @discardableResult
  public func update<V>(
    for key: DefaultedCodedKey<V>,
    expiry: MMKVExpiry? = nil,
    _ body: (inout V) throws -> Void
  ) throws -> Bool {
    try self.withExclusiveLock { store in
      if let error = MMKVErrors.unavailable(store) {
        throw error
      }
      var value = try store.value(for: key)
      try body(&value)
      return try store.set(value, for: key, expiry: expiry)
    }
  }
}

// MARK: - Keys Under A Prefix

extension MMKVStore {
  /// Decodes the value spread over the keys under `prefix`, lets `body` change it, and encodes
  /// the result back into those keys, with no other thread or process able to write to the
  /// store in between.
  ///
  /// ```swift
  /// try store.update(keysUnder: "settings", as: Settings.self) { $0.theme = "dark" }
  /// try store.update(keysUnder: "profile", as: Profile?.self) { $0 = nil }
  /// ```
  ///
  /// The value is read as ``decode(_:fromKeysUnder:options:)`` reads it and written as
  /// ``encode(_:intoKeysUnder:removingOtherKeys:expiry:options:)`` writes it. So a `T` that
  /// needs keys the store does not have is an error, an optional `T` is `nil` when the store
  /// has neither `prefix` nor any key under it, and setting an optional to `nil` removes all
  /// of those keys.
  ///
  /// Every key of the value is written, and not only those of the properties `body` changed,
  /// and each is given `expiry` or the store's default. Listeners are told about all of them
  /// together, once they are written.
  ///
  /// The store is locked as ``withExclusiveLock(_:)`` locks it, so `body` may read and write
  /// the store, and must not wait for another thread that uses it.
  ///
  /// - Parameters:
  ///   - prefix: The start of the keys the value is kept in.
  ///   - type: The type to decode and encode.
  ///   - removingOtherKeys: Whether to remove the keys under `prefix` that the result does not
  ///     write.
  ///   - expiry: How long to keep the value. See ``set(_:forKey:expiry:)``.
  ///   - options: How the value is laid out in keys.
  ///   - body: Changes the value in place. If it throws, nothing is written.
  /// - Returns: Whether every key was stored.
  /// - Throws: Whatever decoding throws, in which case `body` is not run. Whatever `body` or
  ///   encoding throws, in which case nothing is written.
  ///   ``MMKVError/Code/storeIsSuspended`` or ``MMKVError/Code/storeIsClosed`` if the store is
  ///   suspended or closed, without `body` being run.
  @discardableResult
  public func update<T: Codable>(
    keysUnder prefix: String,
    as type: T.Type = T.self,
    removingOtherKeys: Bool = true,
    expiry: MMKVExpiry? = nil,
    options: MMKVKeyCodingOptions = MMKVKeyCodingOptions(),
    _ body: (inout T) throws -> Void
  ) throws -> Bool {
    try self.withExclusiveLock { store in
      var value = try store.decode(T.self, fromKeysUnder: prefix, options: options)
      try body(&value)
      return try store.encode(
        value,
        intoKeysUnder: prefix,
        removingOtherKeys: removingOtherKeys,
        expiry: expiry,
        options: options
      )
    }
  }
}
