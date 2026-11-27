#if canImport(Darwin)
  import Darwin
#elseif canImport(Android)
  import Android
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

/// Keeps the process running while stores hold their file locks, with one expiring activity for
/// every operation that overlaps another or follows it closely.
///
/// The first operation starts an activity, and those that overlap it or follow within `linger`
/// share it. The activity ends once `linger` passes with no operation, so the process can be
/// suspended again soon after it goes idle. If the system is about to suspend the process while
/// the activity is still running, `onExpiration` runs, and the activity ends once it returns.
package final class ExpiringActivity: @unchecked Sendable {
  /// Starts an expiring activity, as `ProcessInfo.performExpiringActivity(withReason:using:)`
  /// does.
  ///
  /// It runs `block` on another thread: with `false` once the process is being kept running,
  /// which it is until `block` returns, or with `true` if it cannot be. If the process is about
  /// to be suspended while `block` is still running, it runs `block` again with `true`.
  package typealias Starter =
    @Sendable (_ reason: String, _ block: @escaping @Sendable (_ expired: Bool) -> Void) -> Void

  private enum Status {
    case starting, running, refused, ended
  }

  /// One activity that was asked for, from being started until it has ended. Guarded by the
  /// activity's mutex.
  private final class Run: @unchecked Sendable {
    var status = Status.starting
    var isExpiring = false
  }

  private let start: Starter
  private let linger: Duration
  private let onExpiration: @Sendable () -> Void
  private let mutex: UnsafeMutablePointer<pthread_mutex_t>
  private let didChange: UnsafeMutablePointer<pthread_cond_t>
  /// The activity operations join, if one is starting or running.
  private var current: Run?
  private var operationCount = 0
  /// Whether an operation joined since the activity last checked for being idle.
  private var wasUsed = false

  /// - Parameters:
  ///   - start: Starts an activity. It must run its block on another thread.
  ///   - linger: How long the activity outlives the last operation.
  ///   - onExpiration: Runs when the process is about to be suspended, on a thread of `start`'s
  ///     choosing. It must leave nothing holding a file lock by the time it returns.
  package init(
    linger: Duration = .seconds(1),
    start: @escaping Starter,
    onExpiration: @escaping @Sendable () -> Void
  ) {
    self.start = start
    self.linger = linger
    self.onExpiration = onExpiration
    self.mutex = .allocate(capacity: 1)
    self.didChange = .allocate(capacity: 1)
    pthread_mutex_init(self.mutex, nil)
    pthread_cond_init(self.didChange, nil)
  }

  deinit {
    pthread_cond_destroy(self.didChange)
    pthread_mutex_destroy(self.mutex)
    self.didChange.deallocate()
    self.mutex.deallocate()
  }

  /// Begins an operation, starting an activity unless one is already running.
  ///
  /// - Returns: Whether the process is kept running. If so, the operation must call ``leave()``
  ///   when done.
  func enter() -> Bool {
    pthread_mutex_lock(self.mutex)
    defer { pthread_mutex_unlock(self.mutex) }
    while true {
      let run: Run
      if let current = self.current {
        run = current
      } else {
        run = Run()
        self.current = run
        pthread_mutex_unlock(self.mutex)
        self.start("MMKV file lock") { expired in self.handle(run, expired: expired) }
        pthread_mutex_lock(self.mutex)
      }
      while run.status == .starting {
        pthread_cond_wait(self.didChange, self.mutex)
      }
      switch run.status {
      case .running:
        self.operationCount += 1
        self.wasUsed = true
        return true
      case .refused:
        return false
      case .starting, .ended:
        // It went idle and ended before this thread woke, so start another.
        continue
      }
    }
  }

  /// Ends an operation that ``enter()`` let through.
  func leave() {
    pthread_mutex_lock(self.mutex)
    self.operationCount -= 1
    pthread_mutex_unlock(self.mutex)
  }

  private func handle(_ run: Run, expired: Bool) {
    pthread_mutex_lock(self.mutex)
    defer { pthread_mutex_unlock(self.mutex) }
    switch run.status {
    case .starting where expired:
      self.finish(run, as: .refused)
    case .starting:
      run.status = .running
      pthread_cond_broadcast(self.didChange)
      self.keepRunning(run)
    case .running where expired:
      // The process is about to be suspended. The thread running `keepRunning` ends the
      // activity once `onExpiration` has returned.
      pthread_mutex_unlock(self.mutex)
      self.onExpiration()
      pthread_mutex_lock(self.mutex)
      run.isExpiring = true
      pthread_cond_broadcast(self.didChange)
      while run.status == .running {
        pthread_cond_wait(self.didChange, self.mutex)
      }
    case .running, .refused, .ended:
      break
    }
  }

  /// Holds the activity open until a whole `linger` passes with no operation, or it expires.
  private func keepRunning(_ run: Run) {
    repeat {
      self.wasUsed = false
      var deadline = self.deadline(after: self.linger)
      while !run.isExpiring
        && pthread_cond_timedwait(self.didChange, self.mutex, &deadline) != ETIMEDOUT
      {}
    } while !run.isExpiring && (self.operationCount > 0 || self.wasUsed)
    self.finish(run, as: .ended)
  }

  private func finish(_ run: Run, as status: Status) {
    run.status = status
    if self.current === run {
      self.current = nil
    }
    pthread_cond_broadcast(self.didChange)
  }

  private func deadline(after duration: Duration) -> timespec {
    var now = timespec()
    clock_gettime(CLOCK_REALTIME, &now)
    let (seconds, attoseconds) = duration.components
    let nanoseconds = Int(now.tv_nsec) + Int(attoseconds / 1_000_000_000)
    return timespec(
      tv_sec: now.tv_sec + Int(seconds) + nanoseconds / 1_000_000_000,
      tv_nsec: nanoseconds % 1_000_000_000
    )
  }
}
