/// Describes which MMKV store to open and how to open it.
///
/// A store is a pair of files named after ``id`` inside ``directory``. Opening the same pair
/// twice in one process returns the same underlying store, and the configuration of the first
/// open wins.
///
/// ```swift
/// let configuration = MMKVConfiguration(
///   directory: MMKVDirectory(path: "/path/to/app/files/mmkv"),
///   mode: .singleProcess
/// )
/// let store = try MMKVStore(configuration)
/// ```
public struct MMKVConfiguration: Sendable, Hashable {
  /// The store's identifier, which names its files inside ``directory``.
  public var id: MMKVStore.ID

  /// The directory holding the store's files. It is created if it does not exist, unless the
  /// store is read-only.
  public var directory: MMKVDirectory

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

  /// The implementation of MMKV's core that opens the store.
  ///
  /// The package is moving from the vendored C++ core to one written in Swift. Until that is
  /// done, tests and benchmarks use this to run against either.
  @_spi(Engines) public var engine = Engine.cxx

  /// Creates a configuration.
  ///
  /// - Parameters:
  ///   - id: The store's identifier.
  ///   - directory: The directory holding the store's files.
  ///   - mode: Whether anything else may have the store's files open. There is no default
  ///     because the wrong choice corrupts data: see ``Mode``.
  ///   - isReadOnly: Whether writes are rejected.
  ///   - encryption: The key the store's contents are encrypted with.
  ///   - expectedCapacity: The size in bytes to create the store's file with.
  ///   - recovery: What to do when the store's file fails its integrity check.
  ///   - compareBeforeSet: Whether a write of an identical value is skipped.
  ///   - itemSizeLimit: The largest key-value pair the store accepts, in bytes.
  public init(
    id: MMKVStore.ID = .default,
    directory: MMKVDirectory,
    mode: Mode,
    isReadOnly: Bool = false,
    encryption: Encryption? = nil,
    expectedCapacity: Int = 0,
    recovery: Recovery = .discard,
    compareBeforeSet: Bool = false,
    itemSizeLimit: Int? = nil
  ) {
    self.id = id
    self.directory = directory
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
  /// A configuration for a single-process store in a new temporary directory, for stores that
  /// do not need to last, such as those of tests and previews.
  ///
  /// ```swift
  /// let store = try MMKVStore(.temporary())
  /// ```
  ///
  /// Every call uses a different directory, so the store starts empty. It is a store like any
  /// other, in ``MMKVDirectory/temporary()``, and lasts until the system clears its temporary
  /// directory.
  ///
  /// - Parameter id: The store's identifier.
  public static func temporary(id: MMKVStore.ID = .default) -> MMKVConfiguration {
    MMKVConfiguration(id: id, directory: .temporary(), mode: .singleProcess)
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

  /// An implementation of MMKV's core.
  @_spi(Engines) public enum Engine: String, Sendable, Hashable, CaseIterable {
    /// The C++ core this package vendors.
    case cxx

    /// The Swift core that is replacing it.
    case swift
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
