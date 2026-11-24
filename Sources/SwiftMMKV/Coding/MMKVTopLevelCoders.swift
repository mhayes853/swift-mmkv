/// An encoder that turns a whole `Encodable` value into one output, such as `JSONEncoder`.
///
/// It has the shape of Combine's `TopLevelEncoder`, which is not available on every platform
/// this package supports. An encoder with an `encode(_:)` method of this shape conforms with an
/// empty extension, marked `@retroactive` when the encoder comes from another module:
///
/// ```swift
/// extension MessagePackEncoder: @retroactive MMKVTopLevelEncoder {}
/// ```
public protocol MMKVTopLevelEncoder {
  /// What the encoder produces. A store can hold it when it is an ``MMKVValue``.
  associatedtype Output

  /// Encodes `value`.
  func encode<T: Encodable>(_ value: T) throws -> Output
}

/// A decoder that reads a whole `Decodable` value from one input, such as `JSONDecoder`.
///
/// It has the shape of Combine's `TopLevelDecoder`. See ``MMKVTopLevelEncoder``.
public protocol MMKVTopLevelDecoder {
  /// What the decoder reads. A store can supply it when it is an ``MMKVValue``.
  associatedtype Input

  /// Decodes a `T` from `input`.
  func decode<T: Decodable>(_ type: T.Type, from input: Input) throws -> T
}

extension MMKVStore {
  /// Encodes `value` with `encoder` and stores the result under `key`, replacing any existing
  /// value.
  ///
  /// The whole value is stored under the one key, as whatever the encoder produces.
  ///
  /// ```swift
  /// try store.encode(Settings(fontSize: 16), forKey: "settings", with: JSONEncoder())
  /// ```
  ///
  /// - Parameters:
  ///   - value: The value to encode.
  ///   - key: The key, which must not be empty.
  ///   - expiry: How long to keep the value. See ``set(_:forKey:expiry:)``.
  ///   - encoder: The encoder to use.
  /// - Returns: Whether the encoded value was stored.
  /// - Throws: Whatever `encoder` throws, in which case nothing is stored, or
  ///   ``MMKVError/Code/storeIsSuspended`` if the store is suspended.
  @discardableResult
  public func encode<T: Encodable, Encoder: MMKVTopLevelEncoder>(
    _ value: T,
    forKey key: String,
    expiry: MMKVExpiry? = nil,
    with encoder: Encoder
  ) throws -> Bool where Encoder.Output: MMKVValue {
    let didStore = self.set(try encoder.encode(value), forKey: key, expiry: expiry)
    if !didStore, let error = MMKVErrors.unavailable(self) {
      throw error
    }
    return didStore
  }

  /// Reads the value stored under `key` and decodes it as a `T` with `decoder`.
  ///
  /// ```swift
  /// let settings = try store.decode(Settings.self, forKey: "settings", with: JSONDecoder())
  /// ```
  ///
  /// - Returns: The value, or `nil` if the key has no value.
  /// - Throws: Whatever `decoder` throws when the stored value does not decode, or
  ///   ``MMKVError/Code/storeIsSuspended`` if the store is suspended.
  public func decode<T: Decodable, Decoder: MMKVTopLevelDecoder>(
    _ type: T.Type = T.self,
    forKey key: String,
    with decoder: Decoder
  ) throws -> T? where Decoder.Input: MMKVValue {
    guard let input = self.value(forKey: key, as: Decoder.Input.self) else {
      // A read that was turned away looks like a missing value, so the store is asked afterwards.
      if let error = MMKVErrors.unavailable(self) {
        throw error
      }
      return nil
    }
    return try decoder.decode(type, from: input)
  }
}
