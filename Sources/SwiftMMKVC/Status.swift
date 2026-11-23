import CSwiftMMKV
import SwiftMMKV

extension MMKVError {
  /// The status the C interface reports this error as.
  var status: swiftmmkv_status {
    switch self {
    case .openFailed: swiftmmkv_status(SWIFTMMKV_OPEN_FAILED)
    case .invalidEncryptionKey: swiftmmkv_status(SWIFTMMKV_INVALID_ENCRYPTION_KEY)
    case .rekeyFailed: swiftmmkv_status(SWIFTMMKV_REKEY_FAILED)
    case .appGroupContainerUnavailable:
      swiftmmkv_status(SWIFTMMKV_APP_GROUP_CONTAINER_UNAVAILABLE)
    case .writeFailed: swiftmmkv_status(SWIFTMMKV_WRITE_FAILED)
    case .storeIsOpen: swiftmmkv_status(SWIFTMMKV_STORE_IS_OPEN)
    case .storesAreOpen: swiftmmkv_status(SWIFTMMKV_STORES_ARE_OPEN)
    case .directoryUnreadable: swiftmmkv_status(SWIFTMMKV_DIRECTORY_UNREADABLE)
    case .backupFailed: swiftmmkv_status(SWIFTMMKV_BACKUP_FAILED)
    case .restoreFailed: swiftmmkv_status(SWIFTMMKV_RESTORE_FAILED)
    case .storesNotBackedUp: swiftmmkv_status(SWIFTMMKV_STORES_NOT_BACKED_UP)
    case .storesNotRestored: swiftmmkv_status(SWIFTMMKV_STORES_NOT_RESTORED)
    case .backupInvalid: swiftmmkv_status(SWIFTMMKV_BACKUP_INVALID)
    case .backupIsStoreDirectory: swiftmmkv_status(SWIFTMMKV_BACKUP_IS_STORE_DIRECTORY)
    case .storeIsSuspended: swiftmmkv_status(SWIFTMMKV_STORE_IS_SUSPENDED)
    }
  }
}

/// Runs `body`, and reports what it throws as a status.
func status(of body: () throws(MMKVError) -> Void) -> swiftmmkv_status {
  do throws(MMKVError) {
    try body()
    return swiftmmkv_status(SWIFTMMKV_OK)
  } catch {
    return error.status
  }
}

@c @implementation
public func swiftmmkv_status_message(_ status: swiftmmkv_status) -> UnsafePointer<CChar> {
  let message: StaticString =
    switch Int(status) {
    case Int(SWIFTMMKV_OK): "The operation succeeded."
    case Int(SWIFTMMKV_OPEN_FAILED): "The store could not be opened."
    case Int(SWIFTMMKV_INVALID_ENCRYPTION_KEY):
      "The encryption key is empty or longer than its cipher allows."
    case Int(SWIFTMMKV_REKEY_FAILED): "The store could not be re-encrypted."
    case Int(SWIFTMMKV_STORE_IS_OPEN): "The store is open in this process."
    case Int(SWIFTMMKV_STORES_ARE_OPEN): "Some stores are open in this process."
    case Int(SWIFTMMKV_DIRECTORY_UNREADABLE): "The directory's contents cannot be listed."
    case Int(SWIFTMMKV_STORE_IS_SUSPENDED): "The store is suspended."
    case Int(SWIFTMMKV_INVALID_ARGUMENT): "An argument is not a value this version knows."
    case Int(SWIFTMMKV_BACKUP_FAILED): "The store's files could not be copied into the backup."
    case Int(SWIFTMMKV_RESTORE_FAILED):
      "The store could not be overwritten with its copy in the backup."
    case Int(SWIFTMMKV_STORES_NOT_BACKED_UP): "Some stores could not be copied into the backup."
    case Int(SWIFTMMKV_STORES_NOT_RESTORED):
      "Some stores could not be overwritten with their copies in the backup."
    case Int(SWIFTMMKV_BACKUP_INVALID):
      "The store's copy in the backup does not match its checksum."
    case Int(SWIFTMMKV_BACKUP_IS_STORE_DIRECTORY):
      "The backup directory is the directory the stores are in."
    case Int(SWIFTMMKV_WRITE_FAILED): "The store did not accept a write."
    case Int(SWIFTMMKV_APP_GROUP_CONTAINER_UNAVAILABLE):
      "The app group has no container this process can reach."
    default: "An unknown status."
    }
  // A static string's bytes are NUL-terminated and live for the rest of the process.
  return UnsafeRawPointer(message.utf8Start).assumingMemoryBound(to: CChar.self)
}
