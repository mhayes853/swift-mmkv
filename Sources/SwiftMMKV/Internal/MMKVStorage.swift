import CSwiftMMKVCore

/// The files of the stores in one directory, and what this package does with them without
/// opening a store.
///
/// A store is two files: a data file named after the store's identifier, and a file of the same
/// name ending in `.crc`.
struct MMKVStorage: Sendable, Hashable {
  var path: String
}

// MARK: - File names

extension MMKVStorage {
  /// The directory inside a store directory that holds the stores whose identifiers cannot be
  /// file names.
  private static let hashedDirectoryName = "specialCharacter"
  private static let crcSuffix = ".crc"

  /// The path the data file of the store with this identifier has relative to its directory.
  ///
  /// An identifier that cannot be a file name is replaced by its MD5 hash and moved into a
  /// subdirectory. This repeats what the core does when it opens a store, because the core
  /// only offers it together with creating that subdirectory.
  static func relativePath(forID id: MMKVStore.ID) -> String {
    let unusable: Set<Unicode.Scalar> = ["\\", "/", ":", "*", "?", "\"", "<", ">", "|"]
    let name = id.rawValue
    guard name.unicodeScalars.contains(where: unusable.contains) else { return name }
    return "\(Self.hashedDirectoryName)/\(Self.md5(name))"
  }

  /// The identifier of the store whose data file is at `relativePath`, or `nil` if the path
  /// holds a hash of it instead.
  static func id(forRelativePath relativePath: String) -> MMKVStore.ID? {
    relativePath.contains("/") ? nil : MMKVStore.ID(rawValue: relativePath)
  }

  private static func md5(_ string: String) -> String {
    var digest = [UInt8](repeating: 0, count: 16)
    string.withMMKVBytes { mmkv_md5($0, &digest) }
    return digest.reduce(into: "") { hex, byte in
      hex += byte < 16 ? "0" : ""
      hex += String(byte, radix: 16)
    }
  }

  /// The directory's path as the core spells it: absolute and normalized.
  private var resolvedPath: String {
    var resolved = self.path
    self.path.withMMKVBytes { path in
      _ = forEachCallbackBytes { context, callback in
        mmkv_resolve_directory(path, context, callback)
        return true
      } _: { buffer in
        resolved = String(decoding: buffer, as: UTF8.self)
      }
    }
    return resolved
  }

  /// The paths the data file of the store with this identifier may have.
  private func dataPaths(forID id: MMKVStore.ID) -> [String] {
    let directory = self.resolvedPath
    var paths = ["\(directory)/\(Self.relativePath(forID: id))"]
    #if os(Android)
      // An older MMKV on Android named a store's files after a hash of their path. The core
      // moves such a store to its proper name when it can, and goes on using the old name when
      // it cannot.
      paths.append("\(directory)/\(Self.md5("\(directory)/\(id.rawValue)"))")
    #endif
    return paths
  }
}

// MARK: - Open stores

extension MMKVStorage {
  /// The data file of every store this process has opened, and the store's identifier.
  ///
  /// The core frees a store's instance when its files are removed, which would leave every
  /// ``MMKVStore`` over it holding a dangling pointer, so removal is refused for these. The
  /// lock is held across opening and removing, so that a store cannot be opened while it is
  /// being removed.
  private static let openStores = Lock([String: OpenStore]())

  private struct OpenStore: Sendable, Hashable {
    let id: MMKVStore.ID
    /// The bits of the core's pointer to the instance, which is what its state is filed under.
    let handle: UInt
  }

  /// Runs `open`, and records the store as open if it returns an instance.
  func opening(id: MMKVStore.ID, _ open: () -> OpaquePointer?) -> OpaquePointer? {
    let handle = Self.openStores.withLock { openStores in
      let handle = open()
      if handle != nil {
        for path in self.dataPaths(forID: id) {
          openStores[path] = OpenStore(id: id, handle: UInt(bitPattern: handle))
        }
      }
      return UInt(bitPattern: handle)
    }
    return OpaquePointer(bitPattern: handle)
  }

  /// The identifier of the open store that has one of `dataPaths` as its data file, however
  /// that file's path is spelled.
  private static func openID(
    forDataPaths dataPaths: [String],
    in openStores: [String: OpenStore]
  ) -> MMKVStore.ID? {
    Self.openStore(forDataPaths: dataPaths, in: openStores)?.id
  }

  private static func openStore(
    forDataPaths dataPaths: [String],
    in openStores: [String: OpenStore]
  ) -> OpenStore? {
    func files(_ dataPath: String) -> [FileIdentity] {
      [dataPath, dataPath + Self.crcSuffix].compactMap(FileIdentity.init(path:))
    }
    let targets = Set(dataPaths.flatMap(files))
    for (openPath, store) in openStores {
      if dataPaths.contains(openPath) || files(openPath).contains(where: targets.contains) {
        return store
      }
    }
    return nil
  }

  /// The identifier the open store whose data file is at `relativePath` was opened with.
  func openID(forRelativePath relativePath: String) -> MMKVStore.ID? {
    let dataPath = "\(self.resolvedPath)/\(relativePath)"
    return Self.openStores.withLock { Self.openID(forDataPaths: [dataPath], in: $0) }
  }

  /// The open store with this identifier in this directory.
  private func openStore(id: MMKVStore.ID) -> OpenStore? {
    let dataPaths = self.dataPaths(forID: id)
    return Self.openStores.withLock { Self.openStore(forDataPaths: dataPaths, in: $0) }
  }

  /// Every open store whose files are in this directory.
  private var openStores: [OpenStore] {
    let directories = [self.resolvedPath, "\(self.resolvedPath)/\(Self.hashedDirectoryName)"]
    let identities = Set(directories.compactMap(FileIdentity.init(path:)))
    let stores = Self.openStores.withLock { openStores in
      openStores.filter { openPath, _ in
        let directory = String(openPath[..<(openPath.lastIndex(of: "/") ?? openPath.startIndex)])
        return directories.contains(directory)
          || FileIdentity(path: directory).map(identities.contains) ?? false
      }
    }
    return Array(Set(stores.values))
  }
}

// MARK: - Stores

extension MMKVStorage {
  private var directory: MMKVDirectory {
    MMKVDirectory(path: self.path)
  }

  func contains(id: MMKVStore.ID) -> Bool {
    id.rawValue.withMMKVBytes { id in
      self.path.withMMKVBytes { mmkv_storage_exists(id, $0) }
    }
  }

  /// The path of every store's data file, relative to the directory and in no particular order.
  func relativePaths() throws(MMKVError) -> [String] {
    let hashedDirectory = "\(self.path)/\(Self.hashedDirectoryName)"
    guard
      let names = fileNames(inDirectoryAtPath: self.path),
      let hashedNames = fileNames(inDirectoryAtPath: hashedDirectory)
    else {
      throw MMKVErrors.directoryUnreadable(self.directory)
    }
    let hashedPaths = Self.storeNames(among: hashedNames, inDirectoryAtPath: hashedDirectory)
      .map { "\(Self.hashedDirectoryName)/\($0)" }
    return Self.storeNames(among: names, inDirectoryAtPath: self.path) + hashedPaths
  }

  /// The names that are a regular file with a `.crc` file beside them.
  private static func storeNames(
    among names: [String],
    inDirectoryAtPath path: String
  ) -> [String] {
    let all = Set(names)
    return names.filter { name in
      all.contains(name + Self.crcSuffix)
        && isRegularFile(atPath: "\(path)/\(name)")
        && isRegularFile(atPath: "\(path)/\(name)\(Self.crcSuffix)")
    }
  }

  /// Removes the store with this identifier.
  ///
  /// - Returns: Whether the store had files to remove.
  func remove(id: MMKVStore.ID) throws(MMKVError) -> Bool {
    guard !id.rawValue.isEmpty, !self.path.isEmpty else { return false }
    return try Self.openStores.withLock { openStores throws(MMKVError) in
      let dataPaths = self.dataPaths(forID: id)
      if Self.openID(forDataPaths: dataPaths, in: openStores) != nil {
        throw MMKVErrors.storeIsOpen(id: id, directory: self.directory)
      }
      return id.rawValue.withMMKVBytes { id in
        self.path.withMMKVBytes { mmkv_remove_storage(id, $0) }
      }
    }
  }

  /// Removes the store whose data file is at `relativePath`, for a store whose identifier is
  /// not known and which the core therefore cannot be asked to remove.
  ///
  /// - Returns: Whether the store had files to remove.
  func remove(relativePath: String) throws(MMKVError) -> Bool {
    guard !self.path.isEmpty else { return false }
    return try Self.openStores.withLock { openStores throws(MMKVError) in
      let dataPath = "\(self.resolvedPath)/\(relativePath)"
      let crcPath = dataPath + Self.crcSuffix
      if let id = Self.openID(forDataPaths: [dataPath], in: openStores) {
        throw MMKVErrors.storeIsOpen(id: id, directory: self.directory)
      }
      guard FileIdentity(path: dataPath) != nil || FileIdentity(path: crcPath) != nil else {
        return false
      }
      // The core's steps: every opener of the store locks its `.crc` file to write, so holding
      // that lock waits for a write in progress.
      let didLock: Void? = withExclusiveFileLock(atPath: crcPath) {
        removeFile(atPath: dataPath)
        removeFile(atPath: crcPath)
      }
      if didLock == nil {
        removeFile(atPath: dataPath)
      }
      return true
    }
  }
}

// MARK: - File protection

extension MMKVStorage {
  /// Gives both files of the store with this identifier a data protection class.
  ///
  /// The core creates the files and maps them before this is called, so a new file has the
  /// class it inherited until then. The class belongs to the file, so it holds for the core's
  /// mapping, and for as long as the core rewrites the file in place.
  ///
  /// - Returns: The files that could not be given the class, and the error number of each.
  func setProtectionClass(
    _ protectionClass: Int32,
    forID id: MMKVStore.ID
  ) -> [(path: String, error: Int32)] {
    self.dataPaths(forID: id)
      .flatMap { [$0, $0 + Self.crcSuffix] }
      .filter { FileIdentity(path: $0) != nil }
      .compactMap { path in
        SwiftMMKV.setProtectionClass(protectionClass, ofFileAtPath: path).map { (path, $0) }
      }
  }
}

// MARK: - Backups

extension MMKVStorage {
  /// Whether the checksum recorded for the store with this identifier matches its data.
  func isValid(id: MMKVStore.ID) -> Bool {
    guard self.contains(id: id) else { return false }
    return id.rawValue.withMMKVBytes { id in
      self.path.withMMKVBytes { mmkv_storage_is_valid(id, $0) }
    }
  }

  /// Copies the store with this identifier into `backup`.
  ///
  /// - Returns: Whether there was a store to copy.
  func backUp(id: MMKVStore.ID, to backup: MMKVStorage) throws(MMKVError) -> Bool {
    try self.checkIsNot(backup)
    guard self.contains(id: id) else { return false }
    if backup.openStore(id: id) != nil {
      throw MMKVErrors.storeIsOpen(id: id, directory: backup.directory)
    }
    let didBackUp = try Self.entering(self.openStore(id: id).map { [$0] } ?? []) { _ in
      id.rawValue.withMMKVBytes { id in
        self.path.withMMKVBytes { path in
          backup.path.withMMKVBytes { mmkv_backup_storage(id, path, $0) }
        }
      }
    }
    guard didBackUp else {
      throw MMKVErrors.backupFailed(id: id, directory: self.directory, backup: backup.directory)
    }
    return true
  }

  /// Overwrites the store with this identifier with its copy in `backup`, and tells the
  /// listeners of an open store that it changed.
  ///
  /// - Returns: Whether `backup` held a store to copy.
  func restore(id: MMKVStore.ID, from backup: MMKVStorage) throws(MMKVError) -> Bool {
    try self.checkIsNot(backup)
    guard backup.contains(id: id) else { return false }
    guard backup.isValid(id: id) else {
      throw MMKVErrors.backupInvalid(id: id, backup: backup.directory)
    }
    var restored = [MMKVStoreState]()
    defer {
      for state in restored {
        state.notify(.external)
      }
    }
    let didRestore = try Self.entering(self.openStore(id: id).map { [$0] } ?? []) { states in
      restored = states
      return id.rawValue.withMMKVBytes { id in
        self.path.withMMKVBytes { path in
          backup.path.withMMKVBytes { mmkv_restore_storage(id, path, $0) }
        }
      }
    }
    guard didRestore else {
      throw MMKVErrors.restoreFailed(id: id, directory: self.directory, backup: backup.directory)
    }
    return true
  }

  /// Copies every store into `backup`.
  ///
  /// - Returns: The number of stores copied.
  func backUpAll(to backup: MMKVStorage) throws(MMKVError) -> Int {
    try self.checkIsNot(backup)
    let openInBackup = backup.openStores.map(\.id).sorted()
    guard openInBackup.isEmpty else {
      throw MMKVErrors.storesAreOpen(ids: openInBackup, directory: backup.directory)
    }
    let storeCount = try self.relativePaths().count
    guard storeCount > 0 else { return 0 }
    let count = try Self.entering(self.openStores) { _ in
      self.path.withMMKVBytes { path in
        backup.path.withMMKVBytes { mmkv_backup_all_storage(path, $0) }
      }
    }
    guard count >= storeCount else {
      throw MMKVErrors.storesNotBackedUp(
        count: storeCount - count,
        directory: self.directory,
        backup: backup.directory
      )
    }
    return count
  }

  /// Overwrites every store that has a copy in `backup`, and tells the listeners of the open
  /// ones that they changed.
  ///
  /// - Returns: The number of stores copied.
  func restoreAll(from backup: MMKVStorage) throws(MMKVError) -> Int {
    try self.checkIsNot(backup)
    let relativePaths = try backup.relativePaths()
    guard !relativePaths.isEmpty else { return 0 }
    // A store whose identifier its files do not tell cannot be asked about.
    for id in relativePaths.compactMap(Self.id(forRelativePath:)) where !backup.isValid(id: id) {
      throw MMKVErrors.backupInvalid(id: id, backup: backup.directory)
    }
    var restored = [MMKVStoreState]()
    defer {
      for state in restored {
        state.notify(.external)
      }
    }
    let count = try Self.entering(self.openStores) { states in
      restored = states
      return self.path.withMMKVBytes { path in
        backup.path.withMMKVBytes { mmkv_restore_all_storage(path, $0) }
      }
    }
    guard count >= relativePaths.count else {
      throw MMKVErrors.storesNotRestored(
        count: relativePaths.count - count,
        directory: self.directory,
        backup: backup.directory
      )
    }
    return count
  }

  /// The core takes copying a directory onto itself for a success.
  private func checkIsNot(_ backup: MMKVStorage) throws(MMKVError) {
    let (path, backupPath) = (self.resolvedPath, backup.resolvedPath)
    let isSame =
      path == backupPath
      || FileIdentity(path: path).map { $0 == FileIdentity(path: backupPath) } ?? false
    if isSame {
      throw MMKVErrors.backupIsStoreDirectory(self.directory)
    }
  }

  /// Runs `body`, which takes the file locks of `stores`, unless one of them is suspended.
  ///
  /// The lock on the open stores is not held meanwhile, because `body` waits for the locks of
  /// those stores, and a thread that holds one of them may be opening another store.
  private static func entering<R>(
    _ stores: [OpenStore],
    _ body: ([MMKVStoreState]) -> R
  ) throws(MMKVError) -> R {
    let states = stores.compactMap { MMKVStoreState.existing(forHandle: $0.handle) }
    var entered = [SuspensionGate]()
    defer {
      for gate in entered {
        gate.leave()
      }
    }
    for state in states {
      guard let gate = state.suspensionGate else { continue }
      guard gate.enter() else { throw MMKVErrors.storeIsSuspended(id: state.id) }
      entered.append(gate)
    }
    return body(states)
  }
}
