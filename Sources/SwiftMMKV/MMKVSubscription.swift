/// A cancellable registration, such as a change listener on an ``MMKVStore``.
///
/// Copies share the same state, and the cancellation closure runs at most once, either when
/// ``cancel()`` is first called or when the final copy is released.
///
/// ```swift
/// let subscription = store.subscribe { change in
///   print(change)
/// }
/// subscription.cancel()
/// ```
public struct MMKVSubscription: Sendable {
  private let storage: Storage

  /// Creates a subscription that invokes `onCancel` when it is cancelled or fully released.
  ///
  /// - Parameter onCancel: Runs once, when the subscription is cancelled or fully released.
  public init(onCancel: @escaping @Sendable () -> Void) {
    self.storage = Storage(onCancel: onCancel)
  }

  /// Cancels the subscription. Subsequent calls have no effect.
  public func cancel() {
    self.storage.cancel()
  }

  private final class Storage: Sendable {
    private let onCancel: Lock<(@Sendable () -> Void)?>

    init(onCancel: @escaping @Sendable () -> Void) {
      self.onCancel = Lock(onCancel)
    }

    deinit { self.cancel() }

    func cancel() {
      let action = self.onCancel.withLock { action in
        defer { action = nil }
        return action
      }
      action?()
    }
  }
}
