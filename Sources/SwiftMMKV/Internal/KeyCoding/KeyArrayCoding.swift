/// How a value that is spread over several keys stores its arrays.
enum KeyArrayCoding: Sendable {
  /// Arrays of strings use MMKV's own encoding, and other arrays are refused.
  case native

  /// Arrays are encoded whole by a coder.
  ///
  /// `decode` returns `nil` when the key has no value.
  case coded(
    encode: @Sendable (any Encodable) throws -> KeyWrite,
    decode: @Sendable (any Decodable.Type, MMKVStore, String) throws -> Any?
  )

  init<Encoder: MMKVTopLevelEncoder & Sendable, Decoder: MMKVTopLevelDecoder & Sendable>(
    encoder: Encoder,
    decoder: Decoder
  ) where Encoder.Output: MMKVValue, Decoder.Input == Encoder.Output {
    self = .coded(
      encode: { value in
        let output = try encoder.encode(value)
        return { store, key, expiringIn in store.set(output, forKey: key, expiringIn: expiringIn) }
      },
      decode: { type, store, key in
        guard let input = store.value(forKey: key, as: Decoder.Input.self) else { return nil }
        return try decoder.decode(type, from: input)
      }
    )
  }
}

/// Stores one encoded value under a key.
typealias KeyWrite = (MMKVStore, String, Duration?) -> Bool
