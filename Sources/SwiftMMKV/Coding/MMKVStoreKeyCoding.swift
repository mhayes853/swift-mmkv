// MARK: - Coding into keys

extension MMKVStore {
  /// Stores each property of `value` under a key of its own, named by `prefix` and the names
  /// along the path to the property.
  ///
  /// ```swift
  /// struct Settings: Codable {
  ///   var fontSize: Double
  ///   var theme: String?
  ///   var sync: Sync
  /// }
  ///
  /// try store.encode(settings, intoKeysUnder: "settings")
  /// // settings.fontSize = 16.0, settings.theme = "dark", settings.sync.isEnabled = true
  /// ```
  ///
  /// This is how to read and write keys that a React Native app stores one by one, as one
  /// value. With the default `options`, numbers are stored as `Double` and arrays as JSON
  /// strings, as JavaScript stores them. To store a value whole under one key instead, see
  /// ``encode(_:forKey:expiry:with:)``.
  ///
  /// An empty `prefix` names the keys by their paths alone, so the properties of `value` become
  /// top-level keys. A `value` that encodes itself as a single value, such as a string, is
  /// stored under `prefix` itself.
  ///
  /// The value is encoded before anything is written, and then written under one exclusive
  /// lock, so listeners hear about each key once. The write is not atomic if the process is
  /// killed part way.
  ///
  /// ## Keys that are not written
  ///
  /// An `Encodable` conformance that the compiler writes skips a property that is `nil`, so
  /// nothing is written to its key. To keep the key from holding on to the value it had,
  /// `prefix` and every key under it that `value` did not write are removed. Reading the value
  /// back then gives what was encoded.
  ///
  /// Every key under `prefix` is therefore taken to belong to `value`. Under an empty `prefix`
  /// that is every key in the store, so encoding there removes everything else the store
  /// holds:
  ///
  /// ```swift
  /// store.set(true, forKey: "hasOnboarded")
  /// try store.encode(settings, intoKeysUnder: "")
  /// store.contains("hasOnboarded")  // false
  /// ```
  ///
  /// Pass `false` for `removingOtherKeys` to remove nothing, which is what to do when other
  /// keys share the prefix. A key is then removed only by a conformance that calls
  /// `encodeNil(forKey:)`, or by encoding `nil` as the whole value, which removes `prefix` and
  /// every key under it.
  ///
  /// - Parameters:
  ///   - value: The value to store.
  ///   - prefix: The start of every key.
  ///   - removingOtherKeys: Whether to remove `prefix` and the keys under it that `value` did
  ///     not write, which reads every key in the store. With an empty `prefix` this removes
  ///     every other key in the store.
  ///   - expiry: How long the keys live. See ``set(_:forKey:expiry:)``.
  ///   - options: How the keys are named, and how numbers and arrays are stored.
  /// - Returns: Whether every key was stored. A value whose type refuses to store it, such as a
  ///   `Decimal` that is not a number, is one that was not.
  /// - Throws: An `EncodingError` if `value` does not encode, in which case nothing is stored,
  ///   or ``MMKVError/Code/storeIsSuspended``.
  @discardableResult
  public func encode<T: Encodable>(
    _ value: T,
    intoKeysUnder prefix: String,
    removingOtherKeys: Bool = true,
    expiry: MMKVExpiry? = nil,
    options: MMKVKeyCodingOptions = MMKVKeyCodingOptions()
  ) throws -> Bool {
    let context = KeyEncodingContext(options)
    let buffer = KeyEncodingBuffer()
    try context.encode(value, at: prefix, codingPath: [], into: buffer)
    return try self.write(
      buffer,
      under: [prefix],
      removingOtherKeys: removingOtherKeys,
      expiry: expiry,
      names: context.names
    )
  }

  /// Stores each value over the keys under its prefix, as
  /// ``encode(_:intoKeysUnder:removingOtherKeys:expiry:options:)`` does for one value.
  ///
  /// ```swift
  /// try store.encode(intoKeysUnder: ("settings", settings), ("profile", profile))
  /// ```
  ///
  /// Every value is encoded before anything is written, so nothing is stored if one of them
  /// does not encode. They are then written under one exclusive lock, in the order given, so a
  /// key that two values write keeps the later one, and listeners hear about each key once.
  ///
  /// The keys under every prefix that none of the values wrote are removed, unless
  /// `removingOtherKeys` is `false`. The store's keys are read once for all of them. An empty
  /// prefix has every key in the store under it: see
  /// ``encode(_:intoKeysUnder:removingOtherKeys:expiry:options:)``.
  ///
  /// - Parameters:
  ///   - values: Each prefix, paired with the value to store under it.
  ///   - removingOtherKeys: Whether to remove the prefixes and the keys under them that the
  ///     values did not write.
  ///   - expiry: How long the keys live. See ``set(_:forKey:expiry:)``.
  ///   - options: How the keys are named, and how numbers and arrays are stored.
  /// - Returns: Whether every key was stored. A value whose type refuses to store it, such as a
  ///   `Decimal` that is not a number, is one that was not.
  /// - Throws: An `EncodingError` if a value does not encode, in which case nothing is stored,
  ///   or ``MMKVError/Code/storeIsSuspended``.
  @discardableResult
  public func encode<each T: Encodable>(
    intoKeysUnder values: repeat (String, each T),
    removingOtherKeys: Bool = true,
    expiry: MMKVExpiry? = nil,
    options: MMKVKeyCodingOptions = MMKVKeyCodingOptions()
  ) throws -> Bool {
    let context = KeyEncodingContext(options)
    let buffer = KeyEncodingBuffer()
    var prefixes = [String]()
    func add<V: Encodable>(_ value: V, under prefix: String) throws {
      try context.encode(value, at: prefix, codingPath: [], into: buffer)
      prefixes.append(prefix)
    }
    repeat try add((each values).1, under: (each values).0)
    return try self.write(
      buffer,
      under: prefixes,
      removingOtherKeys: removingOtherKeys,
      expiry: expiry,
      names: context.names
    )
  }

  private func write(
    _ buffer: KeyEncodingBuffer,
    under prefixes: [String],
    removingOtherKeys: Bool,
    expiry: MMKVExpiry?,
    names: KeyNames
  ) throws -> Bool {
    let didStore = self.withExclusiveLock { store in
      var didStore = true
      var written = Set<String>()
      for operation in buffer.operations {
        switch operation {
        case .set(let key, let write):
          didStore = write(store, key, expiry) && didStore
          written.insert(key)
        case .removeAtOrUnder(let key):
          store.removeAll(keepingCapacity: true) { names.isAtOrUnder($0, key) }
        }
      }
      if removingOtherKeys {
        store.removeAll(keepingCapacity: true) { key in
          !written.contains(key) && prefixes.contains { names.isAtOrUnder(key, $0) }
        }
      }
      return didStore
    }
    if !didStore && self.isSuspended {
      throw MMKVErrors.storeIsSuspended(id: self.id)
    }
    return didStore
  }

  /// Reads a `T` from keys named by `prefix` and the names along the path to each of its
  /// properties, as ``encode(_:intoKeysUnder:removingOtherKeys:expiry:options:)`` stores
  /// them.
  ///
  /// ```swift
  /// let settings = try store.decode(Settings.self, fromKeysUnder: "settings")
  /// let maybe = try store.decode(Settings?.self, fromKeysUnder: "settings")
  /// ```
  ///
  /// Decoding an optional gives `nil` when the store has neither `prefix` nor any key under
  /// it.
  ///
  /// MMKV does not record the type of a value, so a key that was written as a different type
  /// than the property it is read into gives a wrong value, not an error.
  ///
  /// Finding out which keys exist under another reads every key in the store, once. That
  /// happens for an optional that has no value, and for a dictionary.
  ///
  /// - Parameters:
  ///   - type: The type to decode.
  ///   - prefix: The start of every key.
  ///   - options: How the keys are named, and how numbers and arrays are stored.
  /// - Throws: `DecodingError.keyNotFound` if a key that `T` needs has no value, another
  ///   `DecodingError`, or ``MMKVError/Code/storeIsSuspended``.
  public func decode<T: Decodable>(
    _ type: T.Type = T.self,
    fromKeysUnder prefix: String,
    options: MMKVKeyCodingOptions = MMKVKeyCodingOptions()
  ) throws -> T {
    try self.withExclusiveLock { store in
      try KeyDecodingContext(store: store, options: options)
        .decode(type, at: prefix, codingPath: [])
    }
  }

  /// Reads each value from the keys under its prefix, as ``decode(_:fromKeysUnder:options:)``
  /// does for one value.
  ///
  /// ```swift
  /// let (settings, profile) = try store.decode(
  ///   fromKeysUnder: ("settings", Settings.self), ("profile", Profile?.self)
  /// )
  /// ```
  ///
  /// The values are read under one exclusive lock, so they come from the same state of the
  /// store, and the store's keys are read at most once for all of them.
  ///
  /// - Parameters:
  ///   - values: Each prefix, paired with the type to decode from the keys under it.
  ///   - options: How the keys are named, and how numbers and arrays are stored.
  /// - Throws: `DecodingError.keyNotFound` if a key that a type needs has no value, another
  ///   `DecodingError`, or ``MMKVError/Code/storeIsSuspended``.
  public func decode<each T: Decodable>(
    fromKeysUnder values: repeat (String, (each T).Type),
    options: MMKVKeyCodingOptions = MMKVKeyCodingOptions()
  ) throws -> (repeat each T) {
    try self.withExclusiveLock { store in
      let context = KeyDecodingContext(store: store, options: options)
      return (repeat try context.decode((each values).1, at: (each values).0, codingPath: []))
    }
  }
}

// MARK: - Removal

extension MMKVStore {
  /// Removes `prefix` and every key under it, which is every key that
  /// ``encode(_:intoKeysUnder:removingOtherKeys:expiry:options:)`` could have written for
  /// that prefix.
  ///
  /// ```swift
  /// store.removeValues(underKey: "settings")  // settings, settings.theme, settings.sync.isEnabled
  /// ```
  ///
  /// A key is under `prefix` when it starts with `prefix` and `separator`. An empty `prefix`
  /// has every key under it. This reads every key in the store.
  ///
  /// - Parameters:
  ///   - prefix: The start of the keys to remove.
  ///   - separator: What joins a prefix and the rest of a key.
  public func removeValues(underKey prefix: String, separator: String = ".") {
    self.removeValues(underKeys: CollectionOfOne(prefix), separator: separator)
  }

  /// Removes each of `prefixes` and every key under one of them. See
  /// ``removeValues(underKey:separator:)``.
  ///
  /// The store's keys are read once, however many prefixes there are.
  ///
  /// - Parameters:
  ///   - prefixes: The starts of the keys to remove.
  ///   - separator: What joins a prefix and the rest of a key.
  public func removeValues(underKeys prefixes: some Sequence<String>, separator: String = ".") {
    let names = KeyNames(separator: separator)
    let prefixes = Array(prefixes)
    guard !prefixes.isEmpty else { return }
    self.removeAll(keepingCapacity: true) { key in
      prefixes.contains { names.isAtOrUnder(key, $0) }
    }
  }
}
