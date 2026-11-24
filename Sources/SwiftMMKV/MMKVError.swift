/// An error from opening, re-encrypting, removing, backing up, or restoring an ``MMKVStore``.
///
/// An error has a ``code`` that says what went wrong, to tell errors apart by, and a
/// ``message`` that describes it, naming the store and the directory it is about:
///
/// ```swift
/// do {
///   try directory.removeStore(id: "settings")
/// } catch where error.code == .storeIsOpen {
///   // The store is in use.
/// }
/// ```
///
/// Later versions of this package may throw errors with codes that this version does not have.
public struct MMKVError: Error, Hashable, Sendable {
  /// What went wrong.
  public let code: Code

  /// A description of what went wrong, for a log or a developer to read. Its wording may
  /// change between versions.
  public let message: String

  /// Creates an error.
  public init(code: Code, message: String) {
    self.code = code
    self.message = message
  }
}

extension MMKVError: CustomStringConvertible {
  public var description: String {
    self.message
  }
}

extension MMKVError {
  /// What went wrong, for an ``MMKVError``.
  public struct Code: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
      self.rawValue = rawValue
    }

    /// The store could not be opened, for example because its identifier or its directory's
    /// path is empty.
    public static let openFailed = Self(rawValue: "open-failed")

    /// The encryption key is empty or longer than its cipher allows.
    public static let invalidEncryptionKey = Self(rawValue: "invalid-encryption-key")

    /// The store could not be re-encrypted, for example because it is read-only.
    public static let rekeyFailed = Self(rawValue: "rekey-failed")

    /// The store's file could not be rewritten without its expiries, for example because it is
    /// read-only.
    public static let disableExpiryFailed = Self(rawValue: "disable-expiry-failed")

    /// The app group has no container this process can reach.
    public static let appGroupContainerUnavailable = Self(
      rawValue: "app-group-container-unavailable"
    )

    /// The store did not accept a write to a key. A write fails when the key is empty, the
    /// store is read-only, or the pair exceeds the store's item size limit.
    public static let writeFailed = Self(rawValue: "write-failed")

    /// The store is open in this process, so its files cannot be removed or replaced.
    public static let storeIsOpen = Self(rawValue: "store-is-open")

    /// Some stores are open in this process, so their files were not removed or replaced along
    /// with the rest of their directory's stores.
    public static let storesAreOpen = Self(rawValue: "stores-are-open")

    /// The directory exists but its contents cannot be listed.
    public static let directoryUnreadable = Self(rawValue: "directory-unreadable")

    /// The store's files could not be copied into the backup.
    public static let backupFailed = Self(rawValue: "backup-failed")

    /// The store could not be overwritten with its copy in the backup, for example because it
    /// is open as read-only.
    public static let restoreFailed = Self(rawValue: "restore-failed")

    /// Some stores could not be copied into the backup. The others were.
    public static let storesNotBackedUp = Self(rawValue: "stores-not-backed-up")

    /// Some stores could not be overwritten with their copies in the backup. The others were.
    public static let storesNotRestored = Self(rawValue: "stores-not-restored")

    /// The store's copy in the backup does not match its checksum, so nothing was restored
    /// from it.
    public static let backupInvalid = Self(rawValue: "backup-invalid")

    /// The backup directory is the directory the stores are in.
    public static let backupIsStoreDirectory = Self(rawValue: "backup-is-store-directory")

    /// The store is suspended, so it turned the operation away rather than take its file lock.
    /// The operation can be tried again once the store is resumed.
    public static let storeIsSuspended = Self(rawValue: "store-is-suspended")

    /// The store is closed, so it turns every operation away. Open the store again, as a new
    /// ``MMKVStore``, to use it.
    public static let storeIsClosed = Self(rawValue: "store-is-closed")
  }
}
