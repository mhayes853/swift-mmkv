/// An error from opening, re-encrypting, or removing an ``MMKVStore``.
public enum MMKVError: Error, Sendable, Hashable {
  /// The store could not be opened, for example because its identifier or its directory's path
  /// is empty.
  case openFailed(id: String, directory: MMKVDirectory)

  /// The encryption key is empty or longer than its cipher allows.
  case invalidEncryptionKey

  /// The store could not be re-encrypted, for example because it is read-only.
  case rekeyFailed

  /// The app group named by the `AppGroupIdentifier` key of the app's `Info.plist` has no
  /// container this process can reach.
  case appGroupContainerUnavailable(identifier: String)

  /// The store did not accept a write to `key`. A write fails when the key is empty, the store
  /// is read-only, or the pair exceeds the store's item size limit.
  case writeFailed(key: String)

  /// The store is open in this process, so its files cannot be removed.
  case storeIsOpen(id: String, directory: MMKVDirectory)
}
