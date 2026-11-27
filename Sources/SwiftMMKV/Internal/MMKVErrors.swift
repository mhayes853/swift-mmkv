/// The errors this package throws, each with the message that describes it.
enum MMKVErrors {
  static let invalidEncryptionKey = MMKVError(
    code: .invalidEncryptionKey,
    message: "The encryption key is empty or longer than its cipher allows."
  )

  static let rekeyFailed = MMKVError(
    code: .rekeyFailed,
    message: "The store could not be re-encrypted. A read-only store cannot be."
  )

  static let disableExpiryFailed = MMKVError(
    code: .disableExpiryFailed,
    message: "The store's file could not be rewritten without its expiries. A read-only "
      + "store's cannot be."
  )

  static func openFailed(id: MMKVStore.ID, directory: MMKVDirectory) -> MMKVError {
    MMKVError(
      code: .openFailed,
      message: "The store \(quoted: id) could not be opened in \(quoted: directory)."
    )
  }

  static func wrongEncryptionKey(id: MMKVStore.ID, directory: MMKVDirectory) -> MMKVError {
    MMKVError(
      code: .wrongEncryptionKey,
      message: "The store \(quoted: id) in \(quoted: directory) was written with another "
        + "encryption key than the one it was opened with."
    )
  }

  static func appGroupContainerUnavailable(identifier: String) -> MMKVError {
    MMKVError(
      code: .appGroupContainerUnavailable,
      message: "The app group \(quoted: identifier) has no container this process can reach."
    )
  }

  static func writeFailed(key: String) -> MMKVError {
    MMKVError(
      code: .writeFailed,
      message: "The store did not accept a write to the key \(quoted: key)."
    )
  }

  static func storeIsOpen(id: MMKVStore.ID, directory: MMKVDirectory) -> MMKVError {
    MMKVError(
      code: .storeIsOpen,
      message: "The store \(quoted: id) in \(quoted: directory) is open in this process."
    )
  }

  static func storesAreOpen(ids: [MMKVStore.ID], directory: MMKVDirectory) -> MMKVError {
    let names = ids.map { "\(quoted: $0)" }.joined(separator: ", ")
    return MMKVError(
      code: .storesAreOpen,
      message: "These stores in \(quoted: directory) are open in this process: \(names)."
    )
  }

  static func directoryUnreadable(_ directory: MMKVDirectory) -> MMKVError {
    MMKVError(
      code: .directoryUnreadable,
      message: "The contents of \(quoted: directory) cannot be listed."
    )
  }

  static func backupFailed(
    id: MMKVStore.ID,
    directory: MMKVDirectory,
    backup: MMKVDirectory
  ) -> MMKVError {
    MMKVError(
      code: .backupFailed,
      message: "The store \(quoted: id) in \(quoted: directory) could not be copied into "
        + "\(quoted: backup)."
    )
  }

  static func restoreFailed(
    id: MMKVStore.ID,
    directory: MMKVDirectory,
    backup: MMKVDirectory
  ) -> MMKVError {
    MMKVError(
      code: .restoreFailed,
      message: "The store \(quoted: id) in \(quoted: directory) could not be overwritten with "
        + "its copy in \(quoted: backup)."
    )
  }

  static func storesNotBackedUp(
    count: Int,
    directory: MMKVDirectory,
    backup: MMKVDirectory
  ) -> MMKVError {
    MMKVError(
      code: .storesNotBackedUp,
      message: "\(count) of the stores in \(quoted: directory) could not be copied into "
        + "\(quoted: backup)."
    )
  }

  static func storesNotRestored(
    count: Int,
    directory: MMKVDirectory,
    backup: MMKVDirectory
  ) -> MMKVError {
    MMKVError(
      code: .storesNotRestored,
      message: "\(count) of the stores in \(quoted: directory) could not be overwritten with "
        + "their copies in \(quoted: backup)."
    )
  }

  static func backupInvalid(id: MMKVStore.ID, backup: MMKVDirectory) -> MMKVError {
    MMKVError(
      code: .backupInvalid,
      message: "The copy of the store \(quoted: id) in \(quoted: backup) does not match its "
        + "checksum."
    )
  }

  static func backupIsStoreDirectory(_ directory: MMKVDirectory) -> MMKVError {
    MMKVError(
      code: .backupIsStoreDirectory,
      message: "The backup directory \(quoted: directory) is the directory the stores are in."
    )
  }

  static func storeIsSuspended(id: MMKVStore.ID) -> MMKVError {
    MMKVError(code: .storeIsSuspended, message: "The store \(quoted: id) is suspended.")
  }

  static func storeIsClosed(id: MMKVStore.ID) -> MMKVError {
    MMKVError(code: .storeIsClosed, message: "The store \(quoted: id) is closed.")
  }

  /// The error for an operation that `store` turned away, or `nil` if it is turning none away.
  static func unavailable(_ store: MMKVStore) -> MMKVError? {
    if store.isClosed { return Self.storeIsClosed(id: store.id) }
    if store.isSuspended { return Self.storeIsSuspended(id: store.id) }
    return nil
  }

  /// The error for an operation that the gate of `state` turned away.
  static func unavailable(_ state: MMKVStoreState) -> MMKVError {
    state.gate.isClosed ? Self.storeIsClosed(id: state.id) : Self.storeIsSuspended(id: state.id)
  }
}

extension String.StringInterpolation {
  fileprivate mutating func appendInterpolation(quoted id: MMKVStore.ID) {
    self.appendLiteral("\"\(id.rawValue)\"")
  }

  fileprivate mutating func appendInterpolation(quoted directory: MMKVDirectory) {
    self.appendLiteral("\"\(directory.path)\"")
  }

  fileprivate mutating func appendInterpolation(quoted string: String) {
    self.appendLiteral("\"\(string)\"")
  }
}
