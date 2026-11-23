// Operations on a store's files that do not open it, from MMKV::checkExist, MMKV::removeStorage,
// and getStorage in MMKV_IO.cpp, and Android's tryMigrateLegacyMMKVFile in MMKV_Android.cpp.

package enum StoreStorage {
  /// Whether both of a store's files exist (`checkExist`).
  package static func exists(id: String, rootDirectory: String) -> Bool {
    guard !id.isEmpty, !rootDirectory.isEmpty else { return false }
    return StoreRegistry.withLock {
      guard let paths = Self.paths(id: id, root: StorePaths.normalizedRoot(rootDirectory)) else {
        return false
      }
      return paths.data != nil && paths.meta != nil
    }
  }

  /// Deletes a store's files, under the exclusive file lock so that no other process is using
  /// them (`removeStorage`).
  ///
  /// - Returns: Whether there was anything to delete.
  package static func remove(
    id: String,
    rootDirectory: String,
    fileSystem: FileSystem = .live
  ) -> Bool {
    guard !id.isEmpty, !rootDirectory.isEmpty else { return false }
    return StoreRegistry.withLock {
      guard let paths = Self.paths(id: id, root: StorePaths.normalizedRoot(rootDirectory)),
        paths.data != nil || paths.meta != nil
      else {
        return false
      }
      // A journal is only left behind by a process that stopped while rewriting the data.
      defer {
        if let dataPath = paths.data {
          _ = fileSystem.unlink(StorePaths.journalPath(dataPath: dataPath))
        }
      }
      guard let metaPath = paths.meta else {
        _ = fileSystem.unlink(paths.data!)
        return true
      }
      let descriptor = fileSystem.open(metaPath, O_CLOEXEC | O_RDONLY, S_IRWXU)
      guard descriptor >= 0 else {
        if let dataPath = paths.data {
          _ = fileSystem.unlink(dataPath)
        }
        return true
      }
      defer { _ = fileSystem.close(descriptor) }
      let fileLock = FileLock(descriptor: descriptor, fileSystem: fileSystem)
      fileLock.lock(.exclusive)
      if let dataPath = paths.data {
        _ = fileSystem.unlink(dataPath)
      }
      _ = fileSystem.unlink(metaPath)
      fileLock.unlock(.exclusive)
      return true
    }
  }

  /// The paths of a store's files that exist, or `nil` on Android when neither the store nor its
  /// legacy files exist (`getStorage`).
  private static func paths(id: String, root: String) -> (data: String?, meta: String?)? {
    var realID = id
    #if os(Android)
      switch tryMigrateLegacyFiles(id: id, root: root) {
      case .noneExist: return nil
      case .oldToNewMigrateFail: realID = legacyID(id: id, root: root)
      default: break
      }
    #endif
    let dataPath = StorePaths.dataPath(id: realID, root: root)
    let metaPath = StorePaths.metaPath(dataPath: dataPath)
    return (
      access(dataPath, F_OK) == 0 ? dataPath : nil,
      access(metaPath, F_OK) == 0 ? metaPath : nil
    )
  }

  /// The identifier an older MMKV on Android used for a store in a directory other than the
  /// default one: the MD5 of its path (`legacyMmapedKVKey`).
  package static func legacyID(id: String, root: String) -> String {
    StorePaths.md5Hex("\(root)/\(id)")
  }

  package enum MigrateStatus {
    case notSpecial, noneExist, newExist, oldToNewMigrated, oldToNewMigrateFail, oldAndNewExist
  }

  /// Renames a store's files from the name an older MMKV on Android gave them, if they exist and
  /// the new ones do not (`tryMigrateLegacyMMKVFile`).
  ///
  /// The C++ core checks that no other process has the old files open with an exclusive lock on
  /// bytes 2 to 4 of the data file, although open stores hold their migration lock on the
  /// metadata file. This does the same.
  package static func tryMigrateLegacyFiles(id: String, root: String) -> MigrateStatus {
    let legacy = Self.legacyID(id: id, root: root)
    if legacy == id {
      return .notSpecial
    }
    let path = StorePaths.dataPath(id: legacy, root: root)
    let targetPath = StorePaths.dataPath(id: id, root: root)
    let oldExists = access(path, F_OK) == 0
    let newExists = access(targetPath, F_OK) == 0
    guard oldExists else {
      return newExists ? .newExist : .noneExist
    }
    if newExists {
      Log.warning("both legacy file [\(path)] and new file [\(targetPath)] exist")
      return .oldAndNewExist
    }
    #if os(Linux) || os(Android)
      let descriptor = open(path, O_CLOEXEC | O_RDWR)
      if descriptor >= 0 {
        defer { close(descriptor) }
        let migrationLock = FileLock(
          descriptor: descriptor,
          kind: .openFileDescription(start: 2, length: 3)
        )
        if migrationLock.tryLock(.exclusive).locked {
          defer { migrationLock.unlock(.exclusive) }
          if rename(path, targetPath) == 0
            && rename(
              StorePaths.metaPath(dataPath: path),
              StorePaths.metaPath(dataPath: targetPath)
            )
              == 0
          {
            return .oldToNewMigrated
          }
        }
      }
    #endif
    return .oldToNewMigrateFail
  }
}
