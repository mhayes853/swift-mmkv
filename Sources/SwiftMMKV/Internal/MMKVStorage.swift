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

  /// The path of every store's data file, relative to the directory and in no particular order.
  func relativePaths() throws(MMKVError) -> [String] {
    var paths = [String]()
    let didRead = self.directory.path.withMMKVBytes { directory in
      forEachCallbackBytes { context, callback in
        mmkv_list_storage(directory, context, callback)
      } _: { buffer in
        paths.append(String(decoding: buffer, as: UTF8.self))
      }
    }
    guard didRead else { throw .directoryUnreadable(self.directory) }
    return paths
  }

  /// Removes a store whose identifier is not known.
  ///
  /// - Returns: Whether the store had files to remove.
  func remove(relativePath: String) throws(MMKVError) -> Bool {
    var openID: String?
    let result = self.directory.path.withMMKVBytes { directory in
      relativePath.withMMKVBytes { relativePath in
        var result = Int32(MMKV_REMOVE_STORAGE_MISSING)
        _ = forEachCallbackBytes { context, callback in
          result = mmkv_remove_storage_at(directory, relativePath, context, callback)
          return true
        } _: { buffer in
          openID = String(decoding: buffer, as: UTF8.self)
        }
        return result
      }
    }
    if let openID {
      throw .storeIsOpen(id: openID, directory: self.directory)
    }
    return result == MMKV_REMOVE_STORAGE_REMOVED
  }

  /// The path the data file of the store with this identifier has relative to its directory.
  static func relativePath(forID id: String) -> String {
    var path = ""
    id.withMMKVBytes { id in
      _ = forEachCallbackBytes { context, callback in
        mmkv_storage_relative_path(id, context, callback)
        return true
      } _: { buffer in
        path = String(decoding: buffer, as: UTF8.self)
      }
    }
    return path
  }
}
