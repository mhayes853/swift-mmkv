/// An error from opening, re-encrypting, removing, backing up, or restoring an ``MMKVStore``.
public enum MMKVError: Error, Sendable, Hashable {
  /// The store could not be opened, for example because its identifier or its directory's path
  /// is empty.
  case openFailed(id: MMKVStore.ID, directory: MMKVDirectory)

  /// The encryption key is empty or longer than its cipher allows.
  case invalidEncryptionKey

  /// The store could not be re-encrypted, for example because it is read-only.
  case rekeyFailed

  /// The store's file could not be rewritten without its expiries, for example because it is
  /// read-only.
  case disableExpiryFailed

  /// The app group has no container this process can reach.
  case appGroupContainerUnavailable(identifier: String)

  /// The store did not accept a write to `key`. A write fails when the key is empty, the store
  /// is read-only, or the pair exceeds the store's item size limit.
  case writeFailed(key: String)

  /// The store is open in this process, so its files cannot be removed.
  case storeIsOpen(id: MMKVStore.ID, directory: MMKVDirectory)

  /// Some stores are open in this process, so their files were not removed along with the rest
  /// of their directory's stores.
  case storesAreOpen(ids: [MMKVStore.ID], directory: MMKVDirectory)

  /// The directory exists but its contents cannot be listed.
  case directoryUnreadable(MMKVDirectory)

  /// The store's files could not be copied into `backup`.
  case backupFailed(id: MMKVStore.ID, directory: MMKVDirectory, backup: MMKVDirectory)

  /// The store could not be overwritten with its copy in `backup`, for example because it is
  /// open as read-only.
  case restoreFailed(id: MMKVStore.ID, directory: MMKVDirectory, backup: MMKVDirectory)

  /// Some stores could not be copied into `backup`. The others were.
  case storesNotBackedUp(count: Int, directory: MMKVDirectory, backup: MMKVDirectory)

  /// Some stores could not be overwritten with their copies in `backup`. The others were.
  case storesNotRestored(count: Int, directory: MMKVDirectory, backup: MMKVDirectory)

  /// The store's copy in `backup` does not match its checksum, so nothing was restored from it.
  case backupInvalid(id: MMKVStore.ID, backup: MMKVDirectory)

  /// The backup directory is the directory the stores are in.
  case backupIsStoreDirectory(MMKVDirectory)

  /// The store is suspended, so it turned the operation away rather than take its file lock.
  /// The operation can be tried again once the store is resumed.
  case storeIsSuspended(id: MMKVStore.ID)
}
