/// Opens stores, handing back the instance already open for the same files, as MMKV's
/// `getMMKVWithID` and the package's `mmkv_open` do. An instance stays open until it is closed.
package enum StoreRegistry {
  private static let lock = ThreadLock()
  nonisolated(unsafe) private static var instances = [String: StoreInstance]()

  package enum OpenError: Error {
    /// The identifier or the directory is empty.
    case invalidConfiguration
    /// The store's data is intact but cannot be decoded with the configuration's encryption key,
    /// or without one.
    case wrongEncryptionKey
  }

  /// Opens the store described by `configuration`.
  ///
  /// A store opened with an encryption key is loaded straight away, and is not kept open if its
  /// data cannot be decoded with that key, so that it can be opened again with the right one. A
  /// store opened without a key is loaded when it is first used, as the C++ core's are.
  package static func open(_ configuration: StoreConfiguration) throws(OpenError) -> StoreInstance {
    guard !configuration.id.isEmpty, !configuration.rootDirectory.isEmpty else {
      throw .invalidConfiguration
    }
    let root = StorePaths.normalizedRoot(configuration.rootDirectory)
    if !configuration.isReadOnly {
      makeDirectories(root)
    }
    return try Self.lock.withLock { () throws(OpenError) in
      let key = StorePaths.instanceKey(id: configuration.id, root: root)
      if let instance = Self.instances[key] {
        if instance.hasUndecodableData {
          throw .wrongEncryptionKey
        }
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
      if configuration.encryptionKey?.isEmpty == false,
        instance.loadAndCheckForWrongEncryptionKey()
      {
        throw .wrongEncryptionKey
      }
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

  /// Forgets `instance`, so that the next open of its files makes a new one, and unmaps and
  /// closes its files (`close`). The caller must make sure that nothing else is using the
  /// instance, or will.
  package static func close(_ instance: StoreInstance) {
    Self.lock.withLock {
      if let key = Self.instances.first(where: { $0.value === instance })?.key {
        Self.instances[key] = nil
      }
    }
    instance.releaseFiles()
  }

  /// The open instance whose object has the address `address`, if there is one.
  package static func instance(atAddress address: UInt) -> StoreInstance? {
    Self.lock.withLock {
      Self.instances.values.first {
        UInt(bitPattern: Unmanaged.passUnretained($0).toOpaque()) == address
      }
    }
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
