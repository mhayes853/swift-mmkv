// MMKV's inter-process locks, from InterProcessLock.h, InterProcessLock.cpp, and
// InterProcessLock_Android.cpp.

package enum LockType {
  case shared
  case exclusive
}

/// A lock on an open file that excludes other processes, and other copies of MMKV in this
/// process, counting nested shared and exclusive locks as `FileLock` does.
///
/// Taking an exclusive lock while holding a shared one upgrades it, and releasing the last
/// exclusive lock while shared ones remain downgrades it back. While upgrading, the shared lock
/// is given up first if the exclusive one cannot be had at once, to avoid two upgraders
/// deadlocking.
///
/// The kind of lock must match what every other copy of MMKV takes on the same file, because
/// `flock` and `fcntl` locks do not see each other on Linux.
package final class FileLock {
  package enum Kind {
    /// `flock` on the whole file. MMKV's lock for every store.
    case flock
    #if os(Linux) || os(Android)
      /// An open file description lock (`F_OFD_SETLK`) on a byte range, which Android's MMKV uses
      /// for its process mode and file migration locks.
      case openFileDescription(start: Int, length: Int)
    #endif
  }

  private var descriptor: Int32
  private let kind: Kind
  private let fileSystem: FileSystem
  private var sharedLockCount = 0
  private var exclusiveLockCount = 0

  package init(descriptor: Int32, kind: Kind = .flock, fileSystem: FileSystem = .live) {
    self.descriptor = descriptor
    self.kind = kind
    self.fileSystem = fileSystem
  }

  deinit {
    guard self.isValid else { return }
    if self.exclusiveLockCount > 0 || self.sharedLockCount > 0 {
      self.sharedLockCount = 0
      self.exclusiveLockCount = 0
      _ = self.platformUnlock(toShared: false)
    }
  }

  private var isValid: Bool {
    self.descriptor >= 0
  }

  @discardableResult
  package func lock(_ type: LockType) -> Bool {
    self.doLock(type, wait: true).locked
  }

  /// Takes the lock only if it is free.
  ///
  /// - Returns: Whether it was taken, and whether failing to take it was because another holder
  ///   has it, so that trying again later might succeed.
  package func tryLock(_ type: LockType) -> (locked: Bool, tryAgain: Bool) {
    self.doLock(type, wait: false)
  }

  private func doLock(_ type: LockType, wait: Bool) -> (locked: Bool, tryAgain: Bool) {
    guard self.isValid else { return (false, false) }
    var unlockFirstIfNeeded = false
    switch type {
    case .shared:
      // A shared lock must not break any existing lock.
      if self.sharedLockCount > 0 || self.exclusiveLockCount > 0 {
        self.sharedLockCount += 1
        return (true, false)
      }
    case .exclusive:
      if self.exclusiveLockCount > 0 {
        self.exclusiveLockCount += 1
        return (true, false)
      }
      // Avoid deadlocking with another process upgrading at the same time.
      if self.sharedLockCount > 0 {
        unlockFirstIfNeeded = true
      }
    }
    let result = self.platformLock(type, wait: wait, unlockFirstIfNeeded: unlockFirstIfNeeded)
    if result.locked {
      switch type {
      case .shared: self.sharedLockCount += 1
      case .exclusive: self.exclusiveLockCount += 1
      }
    }
    return result
  }

  @discardableResult
  package func unlock(_ type: LockType) -> Bool {
    guard self.isValid else { return false }
    var unlockToShared = false
    switch type {
    case .shared:
      guard self.sharedLockCount > 0 else { return false }
      if self.sharedLockCount > 1 || self.exclusiveLockCount > 0 {
        self.sharedLockCount -= 1
        return true
      }
    case .exclusive:
      guard self.exclusiveLockCount > 0 else { return false }
      if self.exclusiveLockCount > 1 {
        self.exclusiveLockCount -= 1
        return true
      }
      // Restore the shared lock once every exclusive lock is released.
      if self.sharedLockCount > 0 {
        unlockToShared = true
      }
    }
    let didUnlock = self.platformUnlock(toShared: unlockToShared)
    if didUnlock {
      switch type {
      case .shared: self.sharedLockCount -= 1
      case .exclusive: self.exclusiveLockCount -= 1
      }
    }
    return didUnlock
  }

  /// Releases everything and forgets the descriptor, which is about to be closed.
  package func destroyAndUnlock() {
    _ = self.platformUnlock(toShared: false)
    self.sharedLockCount = 0
    self.exclusiveLockCount = 0
    self.descriptor = -1
  }

  // MARK: Platform

  private func platformLock(
    _ type: LockType,
    wait: Bool,
    unlockFirstIfNeeded: Bool
  ) -> (locked: Bool, tryAgain: Bool) {
    switch self.kind {
    case .flock:
      let operation = type == .shared ? LOCK_SH : LOCK_EX
      if unlockFirstIfNeeded {
        if self.fileSystem.flock(self.descriptor, operation | LOCK_NB) == 0 {
          return (true, false)
        }
        // Give up the shared lock so that another process upgrading can proceed.
        _ = self.fileSystem.flock(self.descriptor, LOCK_UN)
      }
      if self.fileSystem.flock(self.descriptor, wait ? operation : operation | LOCK_NB) == 0 {
        return (true, false)
      }
      let tryAgain = errno == EWOULDBLOCK
      if unlockFirstIfNeeded {
        // Take the shared lock back.
        _ = self.fileSystem.flock(self.descriptor, LOCK_SH)
      }
      return (false, tryAgain)
    #if os(Linux) || os(Android)
      case .openFileDescription(let start, let length):
        let lockType = Int16(type == .shared ? F_RDLCK : F_WRLCK)
        if unlockFirstIfNeeded {
          if self.fcntl(ofdSetLock, lockType, start, length) == 0 {
            return (true, false)
          }
          _ = self.fcntl(ofdSetLock, Int16(F_UNLCK), start, length)
        }
        let command = wait ? ofdSetLockWait : ofdSetLock
        if self.fcntl(command, lockType, start, length) == 0 {
          return (true, false)
        }
        let tryAgain = errno == EAGAIN
        if unlockFirstIfNeeded {
          _ = self.fcntl(command, Int16(F_RDLCK), start, length)
        }
        return (false, tryAgain)
    #endif
    }
  }

  private func platformUnlock(toShared: Bool) -> Bool {
    switch self.kind {
    case .flock:
      return self.fileSystem.flock(self.descriptor, toShared ? LOCK_SH : LOCK_UN) == 0
    #if os(Linux) || os(Android)
      case .openFileDescription(let start, let length):
        let lockType = Int16(toShared ? F_RDLCK : F_UNLCK)
        return self.fcntl(ofdSetLock, lockType, start, length) == 0
    #endif
    }
  }

  #if os(Linux) || os(Android)
    private func fcntl(_ command: Int32, _ type: Int16, _ start: Int, _ length: Int) -> Int32 {
      var info = flock()
      info.l_type = type
      info.l_whence = Int16(SEEK_SET)
      info.l_start = off_t(start)
      info.l_len = off_t(length)
      info.l_pid = 0
      return withUnsafeMutablePointer(to: &info) {
        fcntlLock(self.descriptor, command, $0)
      }
    }
  #endif
}

#if os(Linux) || os(Android)
  // The Linux values of the open file description lock commands, which not every C library
  // exposes to Swift.
  private let ofdSetLock: Int32 = 37
  private let ofdSetLockWait: Int32 = 38

  // `fcntl` is variadic, so Swift cannot call it with a pointer argument directly.
  @_silgen_name("fcntl")
  private func fcntlLock(
    _ descriptor: Int32,
    _ command: Int32,
    _ info: UnsafeMutablePointer<flock>
  ) -> Int32
#endif

/// One kind of lock on a ``FileLock``, which a store can turn off when it has no other process to
/// exclude (MMKV's `InterProcessLock`).
package struct InterProcessLock {
  private let fileLock: FileLock
  private let type: LockType
  package var isEnabled = true

  package init(fileLock: FileLock, type: LockType) {
    self.fileLock = fileLock
    self.type = type
  }

  package func lock() {
    if self.isEnabled {
      self.fileLock.lock(self.type)
    }
  }

  package func unlock() {
    if self.isEnabled {
      self.fileLock.unlock(self.type)
    }
  }
}

/// A recursive mutex, MMKV's `ThreadLock`.
package final class ThreadLock: @unchecked Sendable {
  private let mutex: UnsafeMutablePointer<pthread_mutex_t>

  package init() {
    self.mutex = .allocate(capacity: 1)
    var attributes = pthread_mutexattr_t()
    pthread_mutexattr_init(&attributes)
    pthread_mutexattr_settype(&attributes, Int32(PTHREAD_MUTEX_RECURSIVE))
    pthread_mutex_init(self.mutex, &attributes)
    pthread_mutexattr_destroy(&attributes)
  }

  deinit {
    pthread_mutex_destroy(self.mutex)
    self.mutex.deallocate()
  }

  package func lock() {
    pthread_mutex_lock(self.mutex)
  }

  package func unlock() {
    pthread_mutex_unlock(self.mutex)
  }

  package func tryLock() -> Bool {
    pthread_mutex_trylock(self.mutex) == 0
  }

  package func withLock<R, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
    self.lock()
    defer { self.unlock() }
    return try body()
  }
}
