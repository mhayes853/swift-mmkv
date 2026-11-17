import CSwiftMMKVCore

/// The files of the stores in one directory, and what this package asks of them without opening
/// a store.
struct MMKVStorage {
  let directory: MMKVDirectory

  func contains(id: String) -> Bool {
    id.withMMKVBytes { id in
      self.directory.path.withMMKVBytes { mmkv_storage_exists(id, $0) }
    }
  }

  /// - Returns: Whether the store had files to remove.
  func remove(id: String) throws(MMKVError) -> Bool {
    let result = id.withMMKVBytes { id in
      self.directory.path.withMMKVBytes { mmkv_remove_storage(id, $0) }
    }
    if result == MMKV_REMOVE_STORAGE_OPEN {
      throw .storeIsOpen(id: id, directory: self.directory)
    }
    return result == MMKV_REMOVE_STORAGE_REMOVED
  }
}
