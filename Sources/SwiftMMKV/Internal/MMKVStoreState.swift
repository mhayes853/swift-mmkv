/// The listeners and pending notifications of one underlying MMKV instance.
///
/// An engine hands back the same instance for every open of a directory and identifier, so this
/// is shared by every ``MMKVStore`` over that instance.
final class MMKVStoreState: Sendable {
  typealias Listener = @Sendable (MMKVStore.Change) -> Void

  private struct Registrations: Sendable {
    var nextIdentifier: UInt64 = 0
    var listeners = [UInt64: Listener]()
    var hasPendingExternalChange = false
    var deferralDepth = 0
  }

  let id: String
  /// Turns operations away while the store is suspended. A single-process store takes no file
  /// lock, so it has nothing to suspend.
  let suspensionGate: SuspensionGate?
  private let registrations = Lock(Registrations())

  private init(id: String, isMultiProcess: Bool) {
    self.id = id
    self.suspensionGate = isMultiProcess ? SuspensionGate() : nil
  }

  var hasListeners: Bool {
    self.registrations.withLock { !$0.listeners.isEmpty }
  }

  func subscribe(_ listener: @escaping Listener) -> MMKVSubscription {
    let identifier = self.registrations.withLock { registrations in
      defer { registrations.nextIdentifier &+= 1 }
      registrations.listeners[registrations.nextIdentifier] = listener
      return registrations.nextIdentifier
    }
    return MMKVSubscription { [weak self] in
      self?.registrations.withLock { _ = $0.listeners.removeValue(forKey: identifier) }
    }
  }

  func notify(_ change: MMKVStore.Change) {
    let listeners = self.registrations.withLock { Array($0.listeners.values) }
    for listener in listeners {
      listener(change)
    }
  }

  /// Records that the engine saw the store's file change underneath it. Called with the engine's
  /// locks held, so listeners are told later, by ``deliverChanges(afterWritingTo:)``.
  private func markExternalChange() {
    self.registrations.withLock { $0.hasPendingExternalChange = true }
  }

  /// Holds external changes back until a matching ``endDeferringExternalChanges()``.
  func beginDeferringExternalChanges() {
    self.registrations.withLock { $0.deferralDepth += 1 }
  }

  func endDeferringExternalChanges() {
    self.registrations.withLock { $0.deferralDepth -= 1 }
  }

  /// Tells listeners about an external change the core noticed during an earlier operation,
  /// unless changes are being deferred, and then about a write to `key` if one was made.
  ///
  /// The registrations are only locked once when there is no external change to report, which
  /// is what nearly every write finds.
  func deliverChanges(afterWritingTo key: String? = nil) {
    let (listeners, hasExternalChange) = self.registrations.withLock { registrations in
      let hasExternalChange =
        registrations.hasPendingExternalChange && registrations.deferralDepth == 0
      if hasExternalChange {
        registrations.hasPendingExternalChange = false
      }
      let listeners =
        hasExternalChange || key != nil ? Array(registrations.listeners.values) : []
      return (listeners, hasExternalChange)
    }
    guard hasExternalChange else {
      if let key {
        for listener in listeners {
          listener(.key(key))
        }
      }
      return
    }
    for listener in listeners {
      listener(.external)
    }
    // The listeners may have changed while they were told about the external change.
    if let key {
      self.notify(.key(key))
    }
  }
}

extension MMKVStoreState {
  private static let all = Lock([UInt: MMKVStoreState]())

  /// Returns the state shared by every store over the engine instance `instance`.
  ///
  /// The first open of an instance decides its mode, as it does in the core.
  static func shared(for instance: UInt, id: String, isMultiProcess: Bool) -> MMKVStoreState {
    Self.all.withLock { states in
      if let state = states[instance] {
        return state
      }
      let state = MMKVStoreState(id: id, isMultiProcess: isMultiProcess)
      states[instance] = state
      return state
    }
  }

  /// Records an external change to the engine instance `instance`.
  static func markExternalChange(instance: UInt) {
    let state = Self.all.withLock { $0[instance] }
    state?.markExternalChange()
  }

  /// Records an external change to every instance of a store with the identifier `id`.
  static func markExternalChange(id: String) {
    let states = Self.all.withLock { states in
      states.values.filter { $0.id == id }
    }
    for state in states {
      state.markExternalChange()
    }
  }
}
