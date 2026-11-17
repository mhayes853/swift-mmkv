#if canImport(Darwin)
  import Darwin
#elseif canImport(Android)
  import Android
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

/// What tells one file from every other, whatever path it is reached by.
struct FileIdentity: Hashable {
  private let device: UInt64
  private let inode: UInt64

  /// The identity of the file at `path`, or `nil` if there is no file there.
  init?(path: String) {
    var status = stat()
    guard stat(path, &status) == 0 else { return nil }
    self.device = UInt64(truncatingIfNeeded: status.st_dev)
    self.inode = UInt64(truncatingIfNeeded: status.st_ino)
  }
}

func isRegularFile(atPath path: String) -> Bool {
  var status = stat()
  guard stat(path, &status) == 0 else { return false }
  return mode_t(status.st_mode) & mode_t(S_IFMT) == mode_t(S_IFREG)
}

/// The names of everything in the directory at `path`. A directory that does not exist has
/// nothing in it.
///
/// - Returns: `nil` if the directory exists but cannot be read.
func fileNames(inDirectoryAtPath path: String) -> [String]? {
  guard let stream = opendir(path) else {
    return errno == ENOENT ? [] : nil
  }
  defer { closedir(stream) }
  var names = [String]()
  while let entry = readdir(stream) {
    let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
      String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
    names.append(name)
  }
  return names
}

func removeFile(atPath path: String) {
  _ = unlink(path)
}

/// Runs `body` while holding an exclusive `flock` on the file at `path`, which is the lock MMKV
/// takes on a store's `.crc` file.
///
/// - Returns: `nil`, without running `body`, if the file cannot be opened.
func withExclusiveFileLock<R>(atPath path: String, _ body: () -> R) -> R? {
  let descriptor = open(path, O_RDONLY | O_CLOEXEC)
  guard descriptor >= 0 else { return nil }
  // Closing the descriptor releases the lock.
  defer { close(descriptor) }
  while flock(descriptor, LOCK_EX) != 0 {
    guard errno == EINTR else { return nil }
  }
  return body()
}
