#if canImport(Darwin)
  import Darwin
#elseif canImport(Android)
  import Android
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

/// Lets a store's operations through until the store is suspended, and tells a suspension when
/// the operations already under way have finished.
///
/// An operation enters the gate before it takes the store's file lock and leaves once it has
/// released it, so that after ``suspend()`` returns nothing holds that lock.
final class SuspensionGate: @unchecked Sendable {
  private let mutex: UnsafeMutablePointer<pthread_mutex_t>
  private let didLeave: UnsafeMutablePointer<pthread_cond_t>
  private var isClosed = false
  /// The threads inside the gate, and how many operations deep each one is. An operation can
  /// contain others, as the body of an exclusive lock does.
  private var threads = [(thread: pthread_t, depth: Int)]()

  init() {
    self.mutex = .allocate(capacity: 1)
    self.didLeave = .allocate(capacity: 1)
    pthread_mutex_init(self.mutex, nil)
    pthread_cond_init(self.didLeave, nil)
  }

  deinit {
    pthread_cond_destroy(self.didLeave)
    pthread_mutex_destroy(self.mutex)
    self.didLeave.deallocate()
    self.mutex.deallocate()
  }

  var isSuspended: Bool {
    pthread_mutex_lock(self.mutex)
    defer { pthread_mutex_unlock(self.mutex) }
    return self.isClosed
  }

  /// Begins an operation.
  ///
  /// A thread that is already inside the gate is always let through, because the operation it
  /// is in the middle of cannot finish otherwise.
  ///
  /// - Returns: Whether the operation may go ahead. If so, it must call ``leave()`` when done.
  func enter() -> Bool {
    pthread_mutex_lock(self.mutex)
    defer { pthread_mutex_unlock(self.mutex) }
    if let index = self.indexOfCurrentThread {
      self.threads[index].depth += 1
      return true
    }
    guard !self.isClosed else { return false }
    self.threads.append((pthread_self(), 1))
    return true
  }

  /// Ends an operation that ``enter()`` let through.
  func leave() {
    pthread_mutex_lock(self.mutex)
    defer { pthread_mutex_unlock(self.mutex) }
    guard let index = self.indexOfCurrentThread else { return }
    self.threads[index].depth -= 1
    if self.threads[index].depth == 0 {
      self.threads.remove(at: index)
      pthread_cond_broadcast(self.didLeave)
    }
  }

  /// Turns new operations away, and waits for those other threads have under way.
  ///
  /// An operation the calling thread is itself in the middle of cannot be waited for, and goes
  /// on holding the file lock until it finishes.
  func suspend() {
    pthread_mutex_lock(self.mutex)
    defer { pthread_mutex_unlock(self.mutex) }
    self.isClosed = true
    while self.threads.contains(where: { pthread_equal($0.thread, pthread_self()) == 0 }) {
      pthread_cond_wait(self.didLeave, self.mutex)
    }
  }

  /// Lets operations through again.
  ///
  /// - Returns: Whether the gate was suspended.
  func resume() -> Bool {
    pthread_mutex_lock(self.mutex)
    defer { pthread_mutex_unlock(self.mutex) }
    defer { self.isClosed = false }
    return self.isClosed
  }

  private var indexOfCurrentThread: Int? {
    let current = pthread_self()
    return self.threads.firstIndex { pthread_equal($0.thread, current) != 0 }
  }
}
