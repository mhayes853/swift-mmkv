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
///
/// While the gate has an ``ExpiringActivity``, the outermost operation on each thread runs inside
/// it, so the process is not suspended while that operation holds the lock. An operation the
/// activity cannot keep the process running for is turned away, as if the store were suspended.
final class SuspensionGate: @unchecked Sendable {
  private let mutex: UnsafeMutablePointer<pthread_mutex_t>
  private let didLeave: UnsafeMutablePointer<pthread_cond_t>
  private var isClosed = false
  /// The threads inside the gate, how many operations deep each one is, and the activity its
  /// outermost operation joined. An operation can contain others, as the body of an exclusive
  /// lock does.
  ///
  /// Each joined activity is retained until its thread leaves. Holding it unmanaged keeps the
  /// array free of reference counting, which every operation would otherwise pay for.
  private var threads = [(thread: pthread_t, depth: Int, activity: Unmanaged<ExpiringActivity>?)]()
  private var activity: ExpiringActivity?

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

  /// Runs the operations that begin from now on inside `activity`, or directly if it is `nil`.
  func setActivity(_ activity: ExpiringActivity?) {
    pthread_mutex_lock(self.mutex)
    defer { pthread_mutex_unlock(self.mutex) }
    self.activity = activity
  }

  /// Stops running operations inside `activity`, unless the gate has another activity by now.
  func removeActivity(_ activity: ExpiringActivity) {
    pthread_mutex_lock(self.mutex)
    defer { pthread_mutex_unlock(self.mutex) }
    if self.activity === activity {
      self.activity = nil
    }
  }

  /// Begins an operation.
  ///
  /// A thread that is already inside the gate is always let through, because the operation it
  /// is in the middle of cannot finish otherwise, and the activity it joined already covers it.
  ///
  /// - Returns: Whether the operation may go ahead. If so, it must call ``leave()`` when done.
  func enter() -> Bool {
    pthread_mutex_lock(self.mutex)
    if let index = self.indexOfCurrentThread {
      self.threads[index].depth += 1
      pthread_mutex_unlock(self.mutex)
      return true
    }
    guard !self.isClosed else {
      pthread_mutex_unlock(self.mutex)
      return false
    }
    let activity = self.activity.map { Unmanaged.passRetained($0) }
    self.threads.append((pthread_self(), 1, activity))
    pthread_mutex_unlock(self.mutex)
    // Starting an activity can wait on the system, so it happens outside the mutex. The thread
    // is already inside, so a suspension waits for it.
    if let activity, !activity.takeUnretainedValue().enter() {
      self.removeCurrentThread()
      activity.release()
      return false
    }
    return true
  }

  /// Ends an operation that ``enter()`` let through.
  func leave() {
    pthread_mutex_lock(self.mutex)
    guard let index = self.indexOfCurrentThread else {
      pthread_mutex_unlock(self.mutex)
      return
    }
    self.threads[index].depth -= 1
    guard self.threads[index].depth == 0 else {
      pthread_mutex_unlock(self.mutex)
      return
    }
    let activity = self.threads.remove(at: index).activity
    pthread_cond_broadcast(self.didLeave)
    pthread_mutex_unlock(self.mutex)
    if let activity {
      activity.takeUnretainedValue().leave()
      activity.release()
    }
  }

  private func removeCurrentThread() {
    pthread_mutex_lock(self.mutex)
    defer { pthread_mutex_unlock(self.mutex) }
    if let index = self.indexOfCurrentThread {
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
