/// Opens stores, handing back the instance already open for the same files, as MMKV's
/// `getMMKVWithID` and the package's `mmkv_open` do. Instances live for the rest of the process.
package enum StoreRegistry {
  private static let lock = ThreadLock()
  nonisolated(unsafe) private static var instances = [String: StoreInstance]()

  /// Opens the store described by `configuration`.
  ///
  /// - Returns: `nil` if the identifier or the directory is empty.
  package static func open(_ configuration: StoreConfiguration) -> StoreInstance? {
    guard !configuration.id.isEmpty, !configuration.rootDirectory.isEmpty else { return nil }
    let root = StorePaths.normalizedRoot(configuration.rootDirectory)
    if !configuration.isReadOnly {
      makeDirectories(root)
    }
    return Self.lock.withLock {
      let key = StorePaths.instanceKey(id: configuration.id, root: root)
      if let instance = Self.instances[key] {
        return instance
      }
      if !configuration.isReadOnly {
        let special = "\(root)/\(StorePaths.specialCharacterDirectoryName)"
        if access(special, F_OK) != 0 {
          makeDirectories(special)
        }
      }
      var configuration = configuration
      #if os(Android)
        // An older MMKV on Android named a store's files after a hash of their path. They are
        // renamed when possible, and used under the old name when not.
        if StoreStorage.tryMigrateLegacyFiles(id: configuration.id, root: root)
          == .oldToNewMigrateFail
        {
          configuration.id = StoreStorage.legacyID(id: configuration.id, root: root)
        }
      #endif
      let instance = StoreInstance(configuration, root: root)
      Self.instances[key] = instance
      return instance
    }
  }
}

extension StoreRegistry {
  /// Runs `body` holding the lock that guards the registry (`g_instanceLock`).
  package static func withLock<R>(_ body: () -> R) -> R {
    Self.lock.withLock(body)
  }
}

/// Creates a directory and any missing parents, as MMKV's `mkPath` does.
@discardableResult
package func makeDirectories(_ path: String) -> Bool {
  var current = ""
  let components = path.split(separator: "/", omittingEmptySubsequences: false)
  for (index, component) in components.enumerated() {
    current += (index == 0 ? "" : "/") + component
    guard !current.isEmpty else { continue }
    var status = stat()
    if stat(current, &status) != 0 {
      if errno != ENOENT || mkdir(current, 0o777) != 0 {
        if index == components.count - 1 {
          return false
        }
      }
    } else if (status.st_mode & S_IFMT) != S_IFDIR {
      return false
    }
  }
  return true
}
