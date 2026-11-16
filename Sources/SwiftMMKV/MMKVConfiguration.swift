/// Describes which MMKV store to open and how to open it.
///
/// A store is a pair of files named after ``id`` inside ``rootDirectory``. Opening the same pair
/// twice in one process returns the same underlying store, and the configuration of the first
/// open wins.
///
/// ```swift
/// let configuration = MMKVConfiguration(
///   rootDirectory: "/path/to/app/files/mmkv",
///   mode: .singleProcess
/// )
/// let store = try MMKVStore(configuration)
/// ```
public struct MMKVConfiguration: Sendable, Hashable {
  /// The identifier react-native-mmkv, and MMKV itself, use for the default store.
  public static let defaultID = "mmkv.default"

  /// The store's identifier, which names its files inside ``rootDirectory``.
  public var id: String

  /// The directory holding the store's files. It is created if it does not exist, unless the
  /// store is read-only.
  public var rootDirectory: String

  /// Whether anything else may have the store's files open.
  public var mode: Mode

  /// Whether writes are rejected.
  public var isReadOnly: Bool

  /// The key the store's contents are encrypted with, or `nil` for a plain-text store.
  public var encryption: Encryption?

  /// The size in bytes to create the store's file with. Zero uses one memory page.
  public var expectedCapacity: Int

  /// What to do when the store's file fails its integrity check.
  public var recovery: Recovery

  /// Whether a write is skipped when the key already holds an identical value, which keeps the
  /// file from growing. MMKV ignores this for encrypted stores and stores with expiring keys.
  public var compareBeforeSet: Bool

  /// The largest key-value pair the store accepts, in bytes, or `nil` for no limit.
  public var itemSizeLimit: Int?

  /// Creates a configuration.
  ///
  /// - Parameters:
  ///   - id: The store's identifier.
  ///   - rootDirectory: The directory holding the store's files.
  ///   - mode: Whether anything else may have the store's files open. There is no default
  ///     because the wrong choice corrupts data: see ``Mode``.
  ///   - isReadOnly: Whether writes are rejected.
  ///   - encryption: The key the store's contents are encrypted with.
  ///   - expectedCapacity: The size in bytes to create the store's file with.
  ///   - recovery: What to do when the store's file fails its integrity check.
  ///   - compareBeforeSet: Whether a write of an identical value is skipped.
  ///   - itemSizeLimit: The largest key-value pair the store accepts, in bytes.
  public init(
    id: String = MMKVConfiguration.defaultID,
    rootDirectory: String,
    mode: Mode,
    isReadOnly: Bool = false,
    encryption: Encryption? = nil,
    expectedCapacity: Int = 0,
    recovery: Recovery = .discard,
    compareBeforeSet: Bool = false,
    itemSizeLimit: Int? = nil
  ) {
    self.id = id
    self.rootDirectory = rootDirectory
    self.mode = mode
    self.isReadOnly = isReadOnly
    self.encryption = encryption
    self.expectedCapacity = expectedCapacity
    self.recovery = recovery
    self.compareBeforeSet = compareBeforeSet
    self.itemSizeLimit = itemSizeLimit
  }
}

extension MMKVConfiguration {
  /// Whether anything other than this copy of MMKV may have a store's files open.
  ///
  /// Every opener of a file must agree on the mode. An opener in single-process mode never locks
  /// the file or looks for changes, so mixing modes loses writes just as two single-process
  /// openers would.
  public enum Mode: Sendable, Hashable {
    /// Nothing else has the store's files open, so reads and writes take no file lock.
    case singleProcess

    /// Another process, or another copy of MMKV in this process, may have the store's files
    /// open. Every operation takes a file lock and picks up the other side's changes.
    ///
    /// An app that links react-native-mmkv has a second copy of MMKV in its process, so a store
    /// shared with JavaScript needs this mode here and `mode: 'multi-process'` there.
    case multiProcess
  }

  /// The cipher and key a store's contents are encrypted with.
  public enum Encryption: Sendable, Hashable {
    /// AES-128 in CFB mode, with a key of 1 to 16 bytes.
    case aes128(key: [UInt8])

    /// AES-256 in CFB mode, with a key of 1 to 32 bytes.
    case aes256(key: [UInt8])

    /// AES-128 with the UTF-8 bytes of `key`, which is how react-native-mmkv passes its
    /// `encryptionKey`.
    public static func aes128(key: String) -> Self {
      .aes128(key: Array(key.utf8))
    }

    /// AES-256 with the UTF-8 bytes of `key`, which is how react-native-mmkv passes its
    /// `encryptionKey`.
    public static func aes256(key: String) -> Self {
      .aes256(key: Array(key.utf8))
    }
  }

  /// What to do when a store's file fails its integrity check, which can happen after the
  /// process is killed in the middle of a write.
  public enum Recovery: Sendable, Hashable {
    /// Discard the file's contents and start empty.
    case discard

    /// Keep whatever key-value pairs can still be read.
    case recover
  }
}
