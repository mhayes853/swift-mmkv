/// A recursive lock that owns the state it protects, and hands it out as one `inout` access at a
/// time.
///
/// The state can only be reached through ``withLock(_:)``, so every access to it is made with the
/// lock held, and inside the closure the compiler checks exclusivity statically, as it does for
/// any `inout` argument. The state lives behind a pointer, so no access is checked at run time.
///
/// The lock is recursive, because a store's exclusive lock (``lock()``) is held across calls that
/// each take it again. What must not happen is a second access while one is open, which would
/// give the same thread two `inout`s to the state: ``withLock(_:)`` stops the process if it is
/// called from inside another ``withLock(_:)`` on the same lock.
package final class StoreLock<State: ~Copyable>: @unchecked Sendable {
  private let mutex = ThreadLock()
  private let state: UnsafeMutablePointer<State>
  /// Whether a ``withLock(_:)`` is running. Read and written only with ``mutex`` held.
  private let isAccessing: UnsafeMutablePointer<Bool>

  package init(_ state: consuming State) {
    self.state = .allocate(capacity: 1)
    self.state.initialize(to: state)
    self.isAccessing = .allocate(capacity: 1)
    self.isAccessing.initialize(to: false)
  }

  deinit {
    self.state.deinitialize(count: 1)
    self.state.deallocate()
    self.isAccessing.deallocate()
  }

  /// Runs `body` with the state, holding the lock.
  @inline(__always)
  package func withLock<R, E: Error>(_ body: (inout State) throws(E) -> R) throws(E) -> R {
    self.mutex.lock()
    defer { self.mutex.unlock() }
    precondition(!self.isAccessing.pointee, "a store's state was reached again while in use")
    self.isAccessing.pointee = true
    defer { self.isAccessing.pointee = false }
    return try body(&self.state.pointee)
  }

  /// Takes the lock without reaching the state, so that this thread's ``withLock(_:)`` calls run
  /// and other threads' wait until ``unlock()``.
  package func lock() {
    self.mutex.lock()
  }

  /// Takes the lock as ``lock()`` does, but only if no other thread holds it.
  package func tryLock() -> Bool {
    self.mutex.tryLock()
  }

  package func unlock() {
    self.mutex.unlock()
  }
}
