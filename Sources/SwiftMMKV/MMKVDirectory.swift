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
  /// A store counts as present when both of its files exist. This does not open the store or
  /// create anything, and a store that was opened but never read or written has no files yet.
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
