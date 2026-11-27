/// The system calls the Swift core makes on files, gathered so that tests can make any of them
/// fail. ``live`` makes the real calls.
package struct FileSystem: Sendable {
  package var open: @Sendable (_ path: String, _ flags: Int32, _ mode: mode_t) -> Int32
  package var close: @Sendable (_ descriptor: Int32) -> Int32
  package var ftruncate: @Sendable (_ descriptor: Int32, _ size: off_t) -> Int32
  package var lseek: @Sendable (_ descriptor: Int32, _ offset: off_t, _ whence: Int32) -> off_t
  package var read:
    @Sendable (_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int
  package var write:
    @Sendable (_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int
  /// The size of an open file, or `nil` if it cannot be read.
  package var fileSize: @Sendable (_ descriptor: Int32) -> Int?
  /// The size of a file by path, or `nil` if it cannot be read.
  package var fileSizeAtPath: @Sendable (_ path: String) -> Int?
  package var mmap:
    @Sendable (
      _ hint: UnsafeMutableRawPointer?, _ size: Int, _ protection: Int32, _ descriptor: Int32
    ) -> UnsafeMutableRawPointer?
  package var munmap: @Sendable (_ address: UnsafeMutableRawPointer, _ size: Int) -> Int32
  package var msync:
    @Sendable (_ address: UnsafeMutableRawPointer, _ size: Int, _ flags: Int32) -> Int32
  /// Has the drive write out what it holds of a file that has been synced to it. Apple's drives
  /// keep synced data in a cache of their own until asked; elsewhere syncing already waits for
  /// the drive, and this does nothing.
  package var flushToDrive: @Sendable (_ descriptor: Int32) -> Int32
  package var flock: @Sendable (_ descriptor: Int32, _ operation: Int32) -> Int32
  package var unlink: @Sendable (_ path: String) -> Int32
  package var rename: @Sendable (_ source: String, _ destination: String) -> Int32

  package static let live = FileSystem(
    open: systemOpen,
    close: systemClose,
    ftruncate: systemFtruncate,
    lseek: systemLseek,
    read: systemRead,
    write: systemWrite,
    fileSize: { descriptor in
      var status = stat()
      return fstat(descriptor, &status) == 0 ? Int(status.st_size) : nil
    },
    fileSizeAtPath: { path in
      var status = stat()
      return stat(path, &status) == 0 ? Int(status.st_size) : nil
    },
    mmap: systemMmap,
    munmap: systemMunmap,
    msync: systemMsync,
    flushToDrive: { descriptor in
      #if canImport(Darwin)
        // Not every file system can do a full sync.
        return fcntl(descriptor, F_FULLFSYNC) == -1 ? fsync(descriptor) : 0
      #else
        return 0
      #endif
    },
    flock: systemFlock,
    unlink: systemUnlink,
    rename: systemRename
  )
}

// At file scope these names refer to the C functions, not to the members above.
@Sendable private func systemOpen(_ path: String, _ flags: Int32, _ mode: mode_t) -> Int32 {
  open(path, flags, mode)
}
@Sendable private func systemClose(_ descriptor: Int32) -> Int32 { close(descriptor) }
@Sendable private func systemFtruncate(_ descriptor: Int32, _ size: off_t) -> Int32 {
  ftruncate(descriptor, size)
}
@Sendable private func systemLseek(_ descriptor: Int32, _ offset: off_t, _ whence: Int32) -> off_t {
  lseek(descriptor, offset, whence)
}
@Sendable private func systemRead(
  _ descriptor: Int32,
  _ buffer: UnsafeMutableRawPointer,
  _ count: Int
) -> Int {
  read(descriptor, buffer, count)
}
@Sendable private func systemWrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int)
  -> Int
{
  write(descriptor, buffer, count)
}
@Sendable private func systemMmap(
  _ hint: UnsafeMutableRawPointer?,
  _ size: Int,
  _ protection: Int32,
  _ descriptor: Int32
) -> UnsafeMutableRawPointer? {
  let address = mmap(hint, size, protection, MAP_SHARED, descriptor, 0)
  // MAP_FAILED, which not every C library exposes to Swift.
  return address == UnsafeMutableRawPointer(bitPattern: -1) ? nil : address
}
@Sendable private func systemMunmap(_ address: UnsafeMutableRawPointer, _ size: Int) -> Int32 {
  munmap(address, size)
}
@Sendable private func systemMsync(
  _ address: UnsafeMutableRawPointer,
  _ size: Int,
  _ flags: Int32
) -> Int32 {
  msync(address, size, flags)
}
@Sendable private func systemFlock(_ descriptor: Int32, _ operation: Int32) -> Int32 {
  flock(descriptor, operation)
}
@Sendable private func systemUnlink(_ path: String) -> Int32 { unlink(path) }
@Sendable private func systemRename(_ source: String, _ destination: String) -> Int32 {
  rename(source, destination)
}

/// The memory page size, which MMKV calls `DEFAULT_MMAP_SIZE`: every file is a multiple of it.
package let pageSize = Int(getpagesize())

/// Rounds `value` up to a multiple of `multiple`.
package func roundUp(_ value: Int, toMultipleOf multiple: Int) -> Int {
  ((value + multiple - 1) / multiple) * multiple
}
