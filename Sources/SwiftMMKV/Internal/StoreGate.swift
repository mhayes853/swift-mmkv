import CSwiftMMKVCore

#if canImport(Darwin)
  import Darwin
#elseif canImport(Android)
  import Android
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

/// Lets a store's operations through until the store is suspended or closed, and tells a
/// suspension or a closure when the operations already under way have finished.
///
/// An operation enters the gate before it touches the store's instance and leaves once it is
/// done with it. So after ``suspend()`` returns nothing holds the store's file lock, and a
/// closed store's instance is only freed once nothing is using it.
///
/// Every read and write passes through, so entering and leaving are one atomic addition and
/// one atomic load each. The mutex and the condition are only for a suspension or a closure,
/// and for an operation that enters or leaves while one is under way.
///
/// While the gate has an ``ExpiringActivity``, each operation that is not inside another of its
/// thread's runs inside it, so the process is not suspended while that operation holds the file
/// lock. An operation the activity cannot keep the process running for is turned away, as if
/// the store were suspended.
final class StoreGate: @unchecked Sendable {
  /// What ``enter()`` and ``enterScope()`` hand back for ``leave(_:)``.
  enum Pass {
    /// The operation is counted among those under way.
    case counted
    /// The operation is counted, and joined this activity, which it must leave.
    case joined(ExpiringActivity)
    /// The operation is inside one of the calling thread's own, which is counted.
    case inside
  }

  /// The operations under way that were counted.
  private let underWay: UnsafeMutablePointer<Int64>
  /// Not zero while the gate is suspended, and once it is closed.
  private let isTurningAway: UnsafeMutablePointer<Int64>
  /// Not zero while the gate has an activity, so that an operation only takes the mutex to
  /// look for one when there is one.
  private let hasActivity: UnsafeMutablePointer<Int64>
  private let mutex: UnsafeMutablePointer<pthread_mutex_t>
  private let didChange: UnsafeMutablePointer<pthread_cond_t>
  // Guarded by the mutex.
  private var hasSuspended = false
  private var hasClosed = false
  /// Frees the store's instance. Set when the store is closed, and taken by whichever thread
  /// finds the gate empty first.
  private var free: (() -> Void)?
  private var hasFreed = false
  private var activity: ExpiringActivity?

  init() {
    self.underWay = .allocate(capacity: 1)
    self.isTurningAway = .allocate(capacity: 1)
    self.hasActivity = .allocate(capacity: 1)
    self.mutex = .allocate(capacity: 1)
    self.didChange = .allocate(capacity: 1)
    self.underWay.initialize(to: 0)
    self.isTurningAway.initialize(to: 0)
    self.hasActivity.initialize(to: 0)
    pthread_mutex_init(self.mutex, nil)
    pthread_cond_init(self.didChange, nil)
  }

  deinit {
    pthread_cond_destroy(self.didChange)
    pthread_mutex_destroy(self.mutex)
    self.didChange.deallocate()
    self.mutex.deallocate()
    self.hasActivity.deallocate()
    self.isTurningAway.deallocate()
    self.underWay.deallocate()
  }

  /// Whether the gate is suspended. A closed gate is not: it cannot be resumed.
  var isSuspended: Bool {
    pthread_mutex_lock(self.mutex)
    defer { pthread_mutex_unlock(self.mutex) }
    return self.hasSuspended && !self.hasClosed
  }

  var isClosed: Bool {
    pthread_mutex_lock(self.mutex)
    defer { pthread_mutex_unlock(self.mutex) }
    return self.hasClosed
  }

  /// Runs the operations that begin from now on inside `activity`, or directly if it is `nil`.
  func setActivity(_ activity: ExpiringActivity?) {
    pthread_mutex_lock(self.mutex)
    defer { pthread_mutex_unlock(self.mutex) }
    self.activity = activity
    mmkv_atomic_store(self.hasActivity, activity == nil ? 0 : 1)
  }

  /// Stops running operations inside `activity`, unless the gate has another activity by now.
  func removeActivity(_ activity: ExpiringActivity) {
    pthread_mutex_lock(self.mutex)
    defer { pthread_mutex_unlock(self.mutex) }
    if self.activity === activity {
      self.activity = nil
      mmkv_atomic_store(self.hasActivity, 0)
    }
  }

  /// Begins an operation that runs none of the caller's code.
  ///
  /// An operation inside one of the calling thread's scopes is always let through, because the
  /// scope cannot finish otherwise, and would leave the store with part of what it meant to
  /// write.
  ///
  /// - Returns: `nil` if the operation is turned away. Otherwise it may go ahead, and must hand
  ///   what is returned to ``leave(_:)`` when done.
  func enter() -> Pass? {
    // Counted before looking, so that a suspension or a closure that has not seen this
    // operation is seen by it.
    mmkv_atomic_add(self.underWay, 1)
    guard mmkv_atomic_load(self.isTurningAway) != 0 else {
      guard mmkv_atomic_load(self.hasActivity) != 0 else { return .counted }
      // The activity a scope of this thread joined already covers the operation.
      return ThreadGateScopes.current.isInside(self) ? .counted : self.joinActivity()
    }
    self.uncount()
    return ThreadGateScopes.current.isInside(self) ? .inside : nil
  }

  /// Joins the gate's activity, if it still has one, on behalf of an operation that has been
  /// counted. A suspension waits for the operation meanwhile.
  ///
  /// - Returns: `nil`, having taken back the operation's count, if the activity cannot keep the
  ///   process running.
  private func joinActivity() -> Pass? {
    pthread_mutex_lock(self.mutex)
    let activity = self.activity
    pthread_mutex_unlock(self.mutex)
    guard let activity else { return .counted }
    // Starting an activity can wait on the system, so it happens outside the mutex.
    guard activity.enter() else {
      self.uncount()
      return nil
    }
    return .joined(activity)
  }

  /// Begins an operation that runs the caller's code, which may begin operations of its own,
  /// and may suspend or close the store.
  ///
  /// - Returns: As ``enter()`` does.
  func enterScope() -> Pass? {
    let scopes = ThreadGateScopes.current
    if scopes.isInside(self) {
      scopes.enter(self)
      return .inside
    }
    mmkv_atomic_add(self.underWay, 1)
    guard mmkv_atomic_load(self.isTurningAway) == 0 else {
      self.uncount()
      return nil
    }
    let pass = mmkv_atomic_load(self.hasActivity) != 0 ? self.joinActivity() : .counted
    if pass != nil {
      scopes.enter(self)
    }
    return pass
  }

  /// Ends an operation that ``enter()`` let through.
  func leave(_ pass: Pass) {
    let activity: ExpiringActivity?
    switch pass {
    case .inside: return
    case .counted: activity = nil
    case .joined(let joined): activity = joined
    }
    mmkv_atomic_add(self.underWay, -1)
    if mmkv_atomic_load(self.isTurningAway) != 0 {
      self.didUncount()
    }
    activity?.leave()
  }

  /// Ends an operation that ``enterScope()`` let through.
  func leaveScope(_ pass: Pass) {
    ThreadGateScopes.current.leave(self)
    self.leave(pass)
  }

  /// Takes back the count of an operation that was turned away.
  private func uncount() {
    mmkv_atomic_add(self.underWay, -1)
    self.didUncount()
  }

  /// Tells a suspension or a closure that may be waiting that an operation has finished.
  private func didUncount() {
    pthread_mutex_lock(self.mutex)
    pthread_cond_broadcast(self.didChange)
    let free = self.takeFreeIfEmpty()
    pthread_mutex_unlock(self.mutex)
    self.run(free)
  }

  /// Turns new operations away, and waits for those other threads have under way.
  ///
  /// A scope the calling thread is itself in the middle of cannot be waited for, and goes on
  /// holding the file lock until it finishes.
  func suspend() {
    pthread_mutex_lock(self.mutex)
    defer { pthread_mutex_unlock(self.mutex) }
    guard !self.hasClosed else { return }
    self.hasSuspended = true
    mmkv_atomic_store(self.isTurningAway, 1)
    self.waitForOtherThreads()
  }

  /// Lets operations through again.
  ///
  /// - Returns: Whether the gate was suspended.
  func resume() -> Bool {
    pthread_mutex_lock(self.mutex)
    defer { pthread_mutex_unlock(self.mutex) }
    guard !self.hasClosed, self.hasSuspended else { return false }
    self.hasSuspended = false
    mmkv_atomic_store(self.isTurningAway, 0)
    return true
  }

  /// Turns new operations away for good, waits for those other threads have under way, and
  /// then runs `free`, which may free what the operations were using.
  ///
  /// `free` runs once, however many times the gate is closed, and every call returns after it
  /// has run. The exception is a call from a thread that is in the middle of a scope: the scope
  /// cannot be waited for, so `free` runs when it leaves the gate.
  ///
  /// - Returns: Whether this call closed the gate, rather than finding it closed.
  func close(_ free: @escaping () -> Void) -> Bool {
    pthread_mutex_lock(self.mutex)
    let didClose = !self.hasClosed
    if didClose {
      self.hasClosed = true
      self.free = free
      mmkv_atomic_store(self.isTurningAway, 1)
    }
    self.waitForOtherThreads()
    let free = self.takeFreeIfEmpty()
    while free == nil, !self.hasFreed, !ThreadGateScopes.current.isInside(self) {
      pthread_cond_wait(self.didChange, self.mutex)
    }
    pthread_mutex_unlock(self.mutex)
    self.run(free)
    return didClose
  }

  /// Called with the mutex held, and after new operations have begun to be turned away.
  private func waitForOtherThreads() {
    // A thread's scopes are counted once, however deep it is in them.
    let own: Int64 = ThreadGateScopes.current.isInside(self) ? 1 : 0
    while mmkv_atomic_load(self.underWay) > own {
      pthread_cond_wait(self.didChange, self.mutex)
    }
  }

  /// Called with the mutex held.
  private func takeFreeIfEmpty() -> (() -> Void)? {
    guard let free = self.free, mmkv_atomic_load(self.underWay) == 0 else { return nil }
    self.free = nil
    return free
  }

  private func run(_ free: (() -> Void)?) {
    guard let free else { return }
    free()
    pthread_mutex_lock(self.mutex)
    self.hasFreed = true
    pthread_cond_broadcast(self.didChange)
    pthread_mutex_unlock(self.mutex)
  }
}

/// The gates the current thread has a scope inside, and how many scopes deep it is in each.
///
/// Each thread has its own, so a thread reads and writes it without a lock.
private final class ThreadGateScopes {
  private var depths = [(gate: ObjectIdentifier, depth: Int)]()

  static var current: ThreadGateScopes {
    if let pointer = pthread_getspecific(threadGateScopesKey) {
      return Unmanaged<ThreadGateScopes>.fromOpaque(pointer).takeUnretainedValue()
    }
    let scopes = ThreadGateScopes()
    pthread_setspecific(threadGateScopesKey, Unmanaged.passRetained(scopes).toOpaque())
    return scopes
  }

  func isInside(_ gate: StoreGate) -> Bool {
    self.index(of: gate) != nil
  }

  func enter(_ gate: StoreGate) {
    if let index = self.index(of: gate) {
      self.depths[index].depth += 1
    } else {
      self.depths.append((ObjectIdentifier(gate), 1))
    }
  }

  func leave(_ gate: StoreGate) {
    guard let index = self.index(of: gate) else { return }
    self.depths[index].depth -= 1
    if self.depths[index].depth == 0 {
      self.depths.remove(at: index)
    }
  }

  private func index(of gate: StoreGate) -> Int? {
    let gate = ObjectIdentifier(gate)
    return self.depths.firstIndex { $0.gate == gate }
  }
}

private func releaseThreadGateScopes(_ pointer: UnsafeMutableRawPointer?) {
  guard let pointer else { return }
  Unmanaged<ThreadGateScopes>.fromOpaque(pointer).release()
}

private let threadGateScopesKey: pthread_key_t = {
  var key = pthread_key_t()
  // The platforms differ over whether the pointer is optional, which `$0` leaves to them.
  pthread_key_create(&key) { releaseThreadGateScopes($0) }
  return key
}()
