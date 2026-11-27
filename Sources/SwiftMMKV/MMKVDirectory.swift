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
  private var storage: MMKVStorage

  /// The directory's path.
  public var path: String {
    get { self.storage.path }
    set { self.storage.path = newValue }
  }

  /// Creates a directory from its path.
  public init(path: String) {
    self.storage = MMKVStorage(path: path)
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

// MARK: - Temporary Directories

extension MMKVDirectory {
  /// A new directory inside the system's temporary directory, for stores that do not need to
  /// last, such as those of tests and previews.
  ///
  /// ```swift
  /// let directory = MMKVDirectory.temporary()
  /// let store = try MMKVStore(MMKVConfiguration(directory: directory, mode: .singleProcess))
  /// ```
  ///
  /// Every call returns a different directory, so the stores in it start empty. Like any
  /// directory this is only a path, and nothing is created until a store is opened in it.
  ///
  /// Nothing removes the directory, and its stores are stores like any other. They last
  /// until the system clears its temporary directory, which it may do whenever the process is
  /// not running.
  ///
  /// The system's temporary directory is the `TMPDIR` environment variable. Where that is not
  /// set it is `/tmp`, or `/data/local/tmp` on Android, which an app cannot write to. Recent
  /// versions of Android set `TMPDIR` to the app's cache directory. On one that does not,
  /// opening a store here throws ``MMKVError/Code/openFailed``, so either set
  /// `TMPDIR` when the app launches or make a directory in the app's cache directory with
  /// ``init(path:)``.
  public static func temporary() -> MMKVDirectory {
    MMKVDirectory(
      path: temporaryDirectory() + "swift-mmkv-"
        + String(UInt64.random(in: .min ... .max), radix: 16)
    )
  }
}

// MARK: - Stores

extension MMKVDirectory {
  /// Whether the directory holds a store with this identifier.
  ///
  /// A store counts as present when both of its files exist, which they do once the store has
  /// been opened. This does not open the store or create anything.
  public func containsStore(id: MMKVStore.ID = .default) -> Bool {
    self.storage.contains(id: id)
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
  /// - Throws: ``MMKVError/Code/storeIsOpen`` if the store is open in this process.
  @discardableResult
  public func removeStore(id: MMKVStore.ID = .default) throws(MMKVError) -> Bool {
    try self.storage.remove(id: id)
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
    public let id: MMKVStore.ID?

    /// The path of the store's data file relative to the directory.
    public let relativePath: String

    fileprivate init(relativePath: String) {
      self.relativePath = relativePath
      self.id = MMKVStorage.id(forRelativePath: relativePath)
    }

    /// Whether this is the store with the given identifier. This can be answered for a store
    /// whose ``id`` is `nil` too, because the identifier's hash can be compared.
    public func isStore(id: MMKVStore.ID) -> Bool {
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
  /// - Throws: ``MMKVError/Code/directoryUnreadable`` if the directory exists but cannot be
  ///   read.
  public var stores: [StoreEntry] {
    get throws(MMKVError) {
      try self.storage.relativePaths().sorted().map(StoreEntry.init)
    }
  }

  /// Deletes the files of a store found by ``stores``, as ``removeStore(id:)`` does.
  ///
  /// - Returns: Whether the store had files to delete.
  /// - Throws: ``MMKVError/Code/storeIsOpen`` if the store is open in this process.
  @discardableResult
  public func removeStore(_ entry: StoreEntry) throws(MMKVError) -> Bool {
    guard let id = entry.id else {
      return try self.storage.remove(relativePath: entry.relativePath)
    }
    return try self.storage.remove(id: id)
  }

  /// Deletes the files of every store in the directory, including those ``stores`` cannot name.
  ///
  /// Stores that are open in this process are left alone, and reported once every other store
  /// has been removed.
  ///
  /// - Returns: The number of stores removed.
  /// - Throws: ``MMKVError/Code/storesAreOpen`` if any store is open in this
  ///   process, or ``MMKVError/Code/directoryUnreadable`` if the directory cannot be read.
  @discardableResult
  public func removeAllStores() throws(MMKVError) -> Int {
    var removedCount = 0
    var openIDs = [MMKVStore.ID]()
    for entry in try self.stores {
      do {
        if try self.removeStore(entry) {
          removedCount += 1
        }
      } catch  where error.code == .storeIsOpen {
        // A store whose files do not tell its identifier is named by the one it was opened
        // with.
        let id = entry.id ?? self.storage.openID(forRelativePath: entry.relativePath)
        guard let id else { throw error }
        openIDs.append(id)
      }
    }
    guard openIDs.isEmpty else {
      throw MMKVErrors.storesAreOpen(ids: openIDs.sorted(), directory: self)
    }
    return removedCount
  }
}

// MARK: - Backups

extension MMKVDirectory {
  /// Whether the store with this identifier has files whose contents match their checksum.
  ///
  /// This reads the store's files without opening it, and is `false` for a store that does not
  /// exist. A store that another process is writing to at that moment can fail the check.
  public func isStoreValid(id: MMKVStore.ID = .default) -> Bool {
    self.storage.isValid(id: id)
  }

  /// Copies the files of the store with this identifier into `backup`, replacing a copy that is
  /// already there.
  ///
  /// A backup is a directory of stores like any other, so its stores can be listed with
  /// ``stores``, opened to look at what they hold, and removed with ``removeStore(id:)``.
  ///
  /// ```swift
  /// let backups = MMKVDirectory(path: documentsPath + "/mmkv-backup")
  /// try directory.backUpStore(id: "settings", to: backups)
  /// ```
  ///
  /// The store's locks are held while its files are copied, so the copy holds every write that
  /// returned before this was called, whichever process made it. The files are copied as they
  /// are, so the copy of an encrypted store is encrypted with the same key.
  ///
  /// - Returns: Whether there was a store to back up.
  /// - Throws: ``MMKVError/Code/backupFailed`` if the files could not be
  ///   copied, ``MMKVError/Code/storeIsOpen`` if this process has the copy in `backup`
  ///   open, ``MMKVError/Code/storeIsSuspended`` if the store is suspended, or
  ///   ``MMKVError/Code/backupIsStoreDirectory`` if `backup` is this directory.
  @discardableResult
  public func backUpStore(
    id: MMKVStore.ID = .default,
    to backup: MMKVDirectory
  ) throws(MMKVError) -> Bool {
    try self.storage.backUp(id: id, to: backup.storage)
  }

  /// Copies the files of every store in the directory into `backup`, including those ``stores``
  /// cannot name.
  ///
  /// - Returns: The number of stores backed up.
  /// - Throws: ``MMKVError/Code/storesNotBackedUp`` if some stores could
  ///   not be copied, ``MMKVError/Code/storesAreOpen`` if this process has stores in
  ///   `backup` open, ``MMKVError/Code/storeIsSuspended`` if a store is suspended,
  ///   ``MMKVError/Code/directoryUnreadable`` if the directory cannot be read, or
  ///   ``MMKVError/Code/backupIsStoreDirectory`` if `backup` is this directory.
  @discardableResult
  public func backUpAllStores(to backup: MMKVDirectory) throws(MMKVError) -> Int {
    try self.storage.backUpAll(to: backup.storage)
  }

  /// Replaces the contents of the store with this identifier with those of its copy in
  /// `backup`, creating the store if it does not exist.
  ///
  /// A store that is open is reloaded, so every ``MMKVStore`` over it reads the restored values
  /// and its listeners are told of an external change. Other processes that have the store
  /// open notice the change as they notice any other.
  ///
  /// The store's file is overwritten in place, because other processes may have it open. If
  /// the process stops partway, the file is left partly written, and the store's
  /// ``MMKVConfiguration/recovery`` decides what the next open makes of it.
  ///
  /// The files are copied as they are, so the copy of an encrypted store can only be read by a
  /// store opened with the key it was backed up with.
  ///
  /// - Returns: Whether `backup` held a copy of the store.
  /// - Throws: ``MMKVError/Code/backupInvalid`` if the copy does not match its
  ///   checksum, ``MMKVError/Code/restoreFailed`` if the store could not be
  ///   overwritten, which includes a store that is open as read-only,
  ///   ``MMKVError/Code/storeIsSuspended`` if the store is suspended, or
  ///   ``MMKVError/Code/backupIsStoreDirectory`` if `backup` is this directory.
  @discardableResult
  public func restoreStore(
    id: MMKVStore.ID = .default,
    from backup: MMKVDirectory
  ) throws(MMKVError) -> Bool {
    try self.storage.restore(id: id, from: backup.storage)
  }

  /// Replaces the contents of every store that has a copy in `backup`, as
  /// ``restoreStore(id:from:)`` does. A store with no copy in `backup` is left alone.
  ///
  /// Nothing is restored if a copy fails its checksum. A copy that ``stores`` cannot name is
  /// not checked.
  ///
  /// - Returns: The number of stores restored.
  /// - Throws: ``MMKVError/Code/backupInvalid`` if a copy does not match its checksum,
  ///   ``MMKVError/Code/storesNotRestored`` if some stores could not be
  ///   overwritten, ``MMKVError/Code/storeIsSuspended`` if a store is suspended,
  ///   ``MMKVError/Code/directoryUnreadable`` if `backup` cannot be read, or
  ///   ``MMKVError/Code/backupIsStoreDirectory`` if `backup` is this directory.
  @discardableResult
  public func restoreAllStores(from backup: MMKVDirectory) throws(MMKVError) -> Int {
    try self.storage.restoreAll(from: backup.storage)
  }
}
