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
  private static let openStores = Lock([String: MMKVStore.ID]())

  /// Runs `open`, and records the store as open if it returns an instance.
  func opening(id: MMKVStore.ID, _ open: () -> OpaquePointer?) -> OpaquePointer? {
    let handle = Self.openStores.withLock { openStores in
      let handle = open()
      if handle != nil {
        for path in self.dataPaths(forID: id) {
          openStores[path] = id
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
    in openStores: [String: MMKVStore.ID]
  ) -> MMKVStore.ID? {
    func files(_ dataPath: String) -> [FileIdentity] {
      [dataPath, dataPath + Self.crcSuffix].compactMap(FileIdentity.init(path:))
    }
    let targets = Set(dataPaths.flatMap(files))
    for (openPath, id) in openStores {
      if dataPaths.contains(openPath) || files(openPath).contains(where: targets.contains) {
        return id
      }
    }
    return nil
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
      throw .directoryUnreadable(self.directory)
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
        throw .storeIsOpen(id: id, directory: self.directory)
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
        throw .storeIsOpen(id: id, directory: self.directory)
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
