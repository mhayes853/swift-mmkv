/// An implementation of MMKV's core: the C++ core this package vendors, or the Swift core that is
/// replacing it.
///
/// An engine is one open instance of a store. Every read and write here is a single operation on
/// that instance; nothing notifies listeners, which is left to ``MMKVStore``. An engine reports a
/// change it notices in the store's file, made by another process or another copy of MMKV, with
/// ``MMKVStoreState/markExternalChange(instance:)`` while it holds its locks.
protocol MMKVEngine: Sendable {
  /// Identifies the underlying instance. Two engines over the same instance have the same value,
  /// so that every ``MMKVStore`` over it shares one ``MMKVStoreState``.
  var instance: UInt { get }

  // MARK: Reads

  func bool(forKey key: String) -> Bool?
  func int32(forKey key: String) -> Int32?
  func uint32(forKey key: String) -> UInt32?
  func int64(forKey key: String) -> Int64?
  func uint64(forKey key: String) -> UInt64?
  func float(forKey key: String) -> Float?
  func double(forKey key: String) -> Double?
  func string(forKey key: String) -> String?
  func strings(forKey key: String) -> [String]?

  /// Calls `body` with the bytes stored under `key`, which are only valid during the call.
  ///
  /// - Returns: The result of `body`, or `nil` if the key has no value.
  func withBytes<R, E: Error>(
    forKey key: String,
    _ body: (RawSpan) throws(E) -> R
  ) throws(E) -> R?

  // MARK: Writes

  // Each returns whether the value was stored. An `expiresInSeconds` of zero never expires.

  func set(_ value: Bool, forKey key: String, expiresInSeconds: UInt32) -> Bool
  func set(_ value: Int32, forKey key: String, expiresInSeconds: UInt32) -> Bool
  func set(_ value: UInt32, forKey key: String, expiresInSeconds: UInt32) -> Bool
  func set(_ value: Int64, forKey key: String, expiresInSeconds: UInt32) -> Bool
  func set(_ value: UInt64, forKey key: String, expiresInSeconds: UInt32) -> Bool
  func set(_ value: Float, forKey key: String, expiresInSeconds: UInt32) -> Bool
  func set(_ value: Double, forKey key: String, expiresInSeconds: UInt32) -> Bool
  func set(_ value: String, forKey key: String, expiresInSeconds: UInt32) -> Bool
  func set(_ value: [String], forKey key: String, expiresInSeconds: UInt32) -> Bool
  func set(bytes: RawSpan, forKey key: String, expiresInSeconds: UInt32) -> Bool

  // MARK: Keys

  var count: Int { get }
  var keys: Set<String> { get }
  func contains(_ key: String) -> Bool

  // MARK: Removal

  func remove(_ key: String) -> Bool
  func remove(_ keys: [String])
  func removeAll(keepingCapacity: Bool)

  // MARK: Import

  /// Copies every key and value of `source`, an engine of the same kind, into this one.
  ///
  /// - Returns: The number of keys copied.
  func importAll(from source: any MMKVEngine) -> Int

  // MARK: Locking and maintenance

  /// Takes the instance's lock, which is recursive on the thread that holds it, and for a
  /// multi-process store also excludes other processes and other copies of MMKV.
  func lock()
  func unlock()

  /// The size of the store's file in bytes.
  var totalSize: Int { get }

  /// The number of bytes of the store's file that hold data.
  var actualSize: Int { get }

  func checkContentChanged()
  func trim()
  func sync()

  /// Re-encrypts the store with `encryption`, which has already been validated, or decrypts it
  /// when `encryption` is `nil`.
  ///
  /// - Returns: Whether the store was re-encrypted.
  func rekey(_ encryption: MMKVConfiguration.Encryption?) -> Bool
}

extension MMKVConfiguration.Encryption {
  /// The raw key bytes.
  var key: [UInt8] {
    switch self {
    case .aes128(let key), .aes256(let key): key
    }
  }

  /// Whether the key has a length its cipher accepts. MMKV pads a shorter key with zeros.
  var isValid: Bool {
    switch self {
    case .aes128(let key): (1...16).contains(key.count)
    case .aes256(let key): (1...32).contains(key.count)
    }
  }
}
