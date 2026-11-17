/// A directory that holds MMKV stores.
///
/// A directory is only a path. Creating one touches nothing on disk, and two directories with
/// the same path are the same directory.
///
/// ```swift
/// let directory = MMKVDirectory(path: "/path/to/app/files/mmkv")
/// let store = try MMKVStore(MMKVConfiguration(directory: directory, mode: .singleProcess))
/// ```
public struct MMKVDirectory: Sendable, Hashable {
  /// The directory's path.
  public var path: String

  /// Creates a directory from its path.
  public init(path: String) {
    self.path = path
  }
}

extension MMKVDirectory {
  /// The directory react-native-mmkv keeps its stores in on Android when its `path` option is
  /// not set, which is the `mmkv` directory inside the app's files directory.
  ///
  /// - Parameter filesDirectory: The path of the app's `Context.getFilesDir()`.
  public static func reactNative(filesDirectory: String) -> MMKVDirectory {
    let separator = filesDirectory.hasSuffix("/") ? "" : "/"
    return MMKVDirectory(path: filesDirectory + separator + "mmkv")
  }
}

// MARK: - Stores

extension MMKVDirectory {
  /// Whether the directory holds a store with this identifier.
  ///
  /// A store counts as present when both of its files exist, which they do once the store has
  /// been opened. This does not open the store or create anything.
  public func containsStore(id: String = MMKVConfiguration.defaultID) -> Bool {
    MMKVStorage(directory: self).contains(id: id)
  }

  /// Deletes the files of the store with this identifier.
  ///
  /// The store's file lock is held while its files are deleted, so this waits for another
  /// process that is in the middle of a write. A process that still has the store open keeps
  /// working on the deleted files, and what it writes afterwards is lost.
  ///
  /// A store that is open in this process cannot be removed, and a store stays open for the
  /// rest of the process once an ``MMKVStore`` has been created for it. Remove a store before
  /// opening it, or empty an open one with ``MMKVStore/removeAll(keepingCapacity:)``.
  ///
  /// - Returns: Whether the store had files to delete.
  /// - Throws: ``MMKVError/storeIsOpen(id:directory:)`` if the store is open in this process.
  @discardableResult
  public func removeStore(id: String = MMKVConfiguration.defaultID) throws(MMKVError) -> Bool {
    try MMKVStorage(directory: self).remove(id: id)
  }
}

// MARK: - Listing

extension MMKVDirectory {
  /// A store found in a directory.
  public struct StoreEntry: Sendable, Hashable {
    /// The store's identifier, or `nil` when it cannot be told from the store's files.
    ///
    /// A store's files are named after its identifier. An identifier that cannot be a file
    /// name, because it contains one of `\ / : * ? " < > |`, is replaced by a hash of itself,
    /// which cannot be turned back into the identifier.
    public let id: String?

    /// The path of the store's data file relative to the directory.
    public let relativePath: String

    fileprivate init(relativePath: String) {
      self.relativePath = relativePath
      self.id = relativePath.contains("/") ? nil : relativePath
    }

    /// Whether this is the store with the given identifier. This can be answered for a store
    /// whose ``id`` is `nil` too, because the identifier's hash can be compared.
    public func isStore(id: String) -> Bool {
      MMKVStorage.relativePath(forID: id) == self.relativePath
    }
  }

  /// Every store in the directory, ordered by ``StoreEntry/relativePath``.
  ///
  /// A store is listed when both of its files exist, which is the test
  /// ``containsStore(id:)`` uses. Listing opens no store. Any other file that has a file of the
  /// same name ending in `.crc` beside it is listed too, which matters when the directory holds
  /// more than stores, as an app group's container does.
  ///
  /// A directory that does not exist has no stores.
  ///
  /// - Throws: ``MMKVError/directoryUnreadable(_:)`` if the directory exists but cannot be
  ///   read.
  public var stores: [StoreEntry] {
    get throws(MMKVError) {
      try MMKVStorage(directory: self).relativePaths().sorted().map(StoreEntry.init)
    }
  }

  /// Deletes the files of a store found by ``stores``, as ``removeStore(id:)`` does.
  ///
  /// - Returns: Whether the store had files to delete.
  /// - Throws: ``MMKVError/storeIsOpen(id:directory:)`` if the store is open in this process.
  @discardableResult
  public func removeStore(_ entry: StoreEntry) throws(MMKVError) -> Bool {
    let storage = MMKVStorage(directory: self)
    guard let id = entry.id else {
      return try storage.remove(relativePath: entry.relativePath)
    }
    return try storage.remove(id: id)
  }

  /// Deletes the files of every store in the directory, including those ``stores`` cannot name.
  ///
  /// Stores that are open in this process are left alone, and reported once every other store
  /// has been removed.
  ///
  /// - Returns: The number of stores removed.
  /// - Throws: ``MMKVError/storesAreOpen(ids:directory:)`` if any store is open in this
  ///   process, or ``MMKVError/directoryUnreadable(_:)`` if the directory cannot be read.
  @discardableResult
  public func removeAllStores() throws(MMKVError) -> Int {
    var removedCount = 0
    var openIDs = [String]()
    for entry in try self.stores {
      do {
        if try self.removeStore(entry) {
          removedCount += 1
        }
      } catch .storeIsOpen(let id, _) {
        openIDs.append(id)
      }
    }
    guard openIDs.isEmpty else {
      throw .storesAreOpen(ids: openIDs.sorted(), directory: self)
    }
    return removedCount
  }
}
