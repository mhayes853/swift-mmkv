// A file mapped into memory, from MemoryFile.h and MemoryFile.cpp.

/// A file mapped into memory with `MAP_SHARED`, whose size is always a whole number of pages.
///
/// A "mayfly" file closes its descriptor as soon as it is mapped and reopens it only when it
/// needs one, as MMKV does for every data file and for the metadata file of a single-process
/// store. A multi-process store keeps its metadata file open, because its file lock lives on that
/// descriptor.
///
/// Not thread-safe: a store keeps its files in the state its lock owns.
package struct MemoryFile: ~Copyable {
  package let path: String
  package let isReadOnly: Bool
  package let isMayflyFD: Bool
  private let fileSystem: FileSystem
  private var descriptor: Int32 = -1

  /// The mapping, or `nil` if the file is not mapped.
  package private(set) var memory: UnsafeMutableRawPointer?

  /// The size of the mapping, which is the file's size when it was last mapped.
  package private(set) var size = 0

  package init(
    path: String,
    expectedCapacity: Int = 0,
    isReadOnly: Bool,
    isMayflyFD: Bool,
    fileSystem: FileSystem = .live
  ) {
    self.path = path
    self.isReadOnly = isReadOnly
    self.isMayflyFD = isMayflyFD
    self.fileSystem = fileSystem
    self.reloadFromFile(expectedCapacity: expectedCapacity)
  }

  deinit {
    if let memory = self.memory {
      _ = self.fileSystem.munmap(memory, self.size)
    }
    if self.descriptor >= 0 {
      _ = self.fileSystem.close(self.descriptor)
    }
  }

  package var isFileValid: Bool {
    (self.isMayflyFD || self.descriptor >= 0) && self.size > 0 && self.memory != nil
  }

  /// The open descriptor, opening a mayfly file's again if needed (`getFd`).
  package var fileDescriptor: Int32 {
    mutating get {
      if self.isMayflyFD {
        _ = self.openIfNeeded()
      }
      return self.descriptor
    }
  }

  /// The size of the file on disk, which another process may have changed since it was mapped.
  package var actualFileSize: Int {
    if !self.isMayflyFD && self.descriptor < 0 {
      return 0
    }
    if self.descriptor >= 0 {
      return self.fileSystem.fileSize(self.descriptor) ?? 0
    }
    return self.fileSystem.fileSizeAtPath(self.path) ?? 0
  }

  private mutating func openIfNeeded() -> Bool {
    guard self.descriptor < 0 else { return true }
    let flags = O_CLOEXEC | (self.isReadOnly ? O_RDONLY : O_RDWR | O_CREAT)
    self.descriptor = self.fileSystem.open(self.path, flags, S_IRWXU)
    return self.descriptor >= 0
  }

  package mutating func cleanMayflyFD() {
    if self.isMayflyFD && self.descriptor >= 0 {
      self.closeDescriptor()
    }
  }

  private mutating func closeDescriptor() {
    if self.descriptor >= 0 && self.fileSystem.close(self.descriptor) == 0 {
      self.descriptor = -1
    }
  }

  /// Resizes the file to `size` rounded up to a whole number of pages, zero-fills what it grew
  /// by, and maps it again.
  ///
  /// - Parameter fileLock: A lock on this file's descriptor to release before a mayfly descriptor
  ///   is closed.
  /// - Returns: Whether the file has its new size and is mapped. On failure the file keeps its
  ///   old size.
  @discardableResult
  package mutating func truncate(to newSize: Int, fileLock: FileLock? = nil) -> Bool {
    if self.isMayflyFD {
      _ = self.openIfNeeded()
    }
    guard self.descriptor >= 0 else { return false }
    if newSize == self.size {
      return true
    }
    if self.isReadOnly {
      return false
    }
    let oldSize = self.size
    var size = newSize
    if size < pageSize || size % pageSize != 0 {
      size = (size / pageSize + 1) * pageSize
    }
    self.size = size
    guard self.fileSystem.ftruncate(self.descriptor, off_t(size)) == 0 else {
      self.size = oldSize
      return false
    }
    if size > oldSize && !self.zeroFill(from: oldSize, count: size - oldSize) {
      self.size = oldSize
      _ = self.fileSystem.ftruncate(self.descriptor, off_t(oldSize))
      return false
    }
    if let memory = self.memory {
      _ = self.fileSystem.munmap(memory, oldSize)
    }
    return self.mapOrCleanUp(fileLock: fileLock)
  }

  private func zeroFill(from start: Int, count: Int) -> Bool {
    guard self.fileSystem.lseek(self.descriptor, off_t(start), SEEK_SET) >= 0 else { return false }
    let zeros = [UInt8](repeating: 0, count: 4_096)
    var remaining = count
    while remaining > 0 {
      let written = zeros.withUnsafeBytes {
        self.fileSystem.write(self.descriptor, $0.baseAddress!, min(remaining, $0.count))
      }
      if written < 0 && errno == EINTR {
        continue
      }
      guard written > 0 else { return false }
      remaining -= written
    }
    return true
  }

  @discardableResult
  package func msync(synchronously: Bool) -> Bool {
    if self.isReadOnly {
      return true
    }
    guard let memory = self.memory else { return false }
    return self.fileSystem.msync(memory, self.size, synchronously ? MS_SYNC : MS_ASYNC) == 0
  }

  private mutating func mapOrCleanUp(fileLock: FileLock?) -> Bool {
    let protection = self.isReadOnly ? PROT_READ : PROT_READ | PROT_WRITE
    // The old address is a hint, so a remapped file tends to stay where it was.
    guard let memory = self.fileSystem.mmap(self.memory, self.size, protection, self.descriptor)
    else {
      self.memory = nil
      self.clearMemoryCache()
      return false
    }
    self.memory = memory
    if self.isMayflyFD, let fileLock {
      fileLock.destroyAndUnlock()
    }
    self.cleanMayflyFD()
    return true
  }

  /// Maps the file, first growing it to `expectedCapacity` rounded up to a whole number of pages,
  /// and at least one page, unless it is read-only.
  ///
  /// The data file's own descriptor is locked while this happens, shared to read its size and
  /// exclusive to grow it, so two copies of MMKV opening the same file do not both resize it.
  package mutating func reloadFromFile(expectedCapacity: Int = 0) {
    if self.isFileValid {
      self.clearMemoryCache()
    }
    guard self.openIfNeeded() else { return }
    let fileLock = FileLock(descriptor: self.descriptor, fileSystem: self.fileSystem)
    fileLock.lock(.shared)
    self.size = self.fileSystem.fileSize(self.descriptor) ?? 0
    let expectedSize = max(pageSize, roundUp(expectedCapacity, toMultipleOf: pageSize))
    if !self.isReadOnly && (self.size < expectedSize || self.size % pageSize != 0) {
      fileLock.lock(.exclusive)
      let roundSize = max(expectedSize, (self.size / pageSize + 1) * pageSize)
      self.truncate(to: roundSize, fileLock: fileLock)
      fileLock.unlock(.exclusive)
    } else {
      _ = self.mapOrCleanUp(fileLock: fileLock)
    }
    fileLock.unlock(.shared)
  }

  /// Maps the file again at its size on disk, which another process may have made smaller than
  /// the mapping.
  ///
  /// - Returns: Whether the file is mapped.
  @discardableResult
  package mutating func remapToFileSize() -> Bool {
    guard self.openIfNeeded() else { return false }
    guard let size = self.fileSystem.fileSize(self.descriptor), size > 0 else {
      self.clearMemoryCache()
      return false
    }
    if let memory = self.memory {
      _ = self.fileSystem.munmap(memory, self.size)
    }
    self.size = size
    return self.mapOrCleanUp(fileLock: nil)
  }

  /// Unmaps the file and closes its descriptor (`clearMemoryCache` and `doCleanMemoryCache`).
  package mutating func clearMemoryCache() {
    if let memory = self.memory {
      _ = self.fileSystem.munmap(memory, self.size)
    }
    self.memory = nil
    self.closeDescriptor()
    self.size = 0
  }
}
