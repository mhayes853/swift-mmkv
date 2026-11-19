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
    var pendingKeys = [String]()
    var deferralDepth = 0
  }

  let id: MMKVStore.ID
  /// Turns operations away while the store is suspended. A single-process store takes no file
  /// lock, so it has nothing to suspend.
  let suspensionGate: SuspensionGate?
  private let registrations = Lock(Registrations())

  private init(id: MMKVStore.ID, isMultiProcess: Bool) {
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

  /// Tells listeners about a change made through this package, or holds it back while changes
  /// are being deferred. A key that is changed more than once in that time is reported once.
  func notify(_ change: MMKVStore.Change) {
    let listeners: [Listener]? = self.registrations.withLock { registrations in
      guard registrations.deferralDepth > 0 else { return Array(registrations.listeners.values) }
      switch change {
      case .key(let key):
        if !registrations.pendingKeys.contains(key) {
          registrations.pendingKeys.append(key)
        }
      case .external:
        registrations.hasPendingExternalChange = true
      }
      return nil
    }
    guard let listeners else { return }
    for listener in listeners {
      listener(change)
    }
  }

  /// Records that the engine saw the store's file change underneath it. Called with the engine's
  /// locks held, so listeners are told later, by ``deliverChanges(afterWritingTo:)``.
  private func markExternalChange() {
    self.registrations.withLock { $0.hasPendingExternalChange = true }
  }

  /// Holds changes back until a matching ``endDeferringChanges()``.
  func beginDeferringChanges() {
    self.registrations.withLock { $0.deferralDepth += 1 }
  }

  func endDeferringChanges() {
    self.registrations.withLock { $0.deferralDepth -= 1 }
  }

  /// Tells listeners about the changes that were held back and about an external change the
  /// engine noticed during an earlier operation, and then about a write to `key` if one was made.
  /// While changes are being deferred, the write is held back with the rest.
  ///
  /// When nothing was held back, which is what nearly every write finds, the registrations are
  /// locked only once.
  func deliverChanges(afterWritingTo key: String? = nil) {
    let delivery: (changes: [MMKVStore.Change], listeners: [Listener], includesKey: Bool)? =
      self.registrations.withLock { registrations in
        guard registrations.deferralDepth == 0 else {
          if let key, !registrations.pendingKeys.contains(key) {
            registrations.pendingKeys.append(key)
          }
          return nil
        }
        var changes = registrations.pendingKeys.map(MMKVStore.Change.key)
        if registrations.hasPendingExternalChange {
          changes.append(.external)
        }
        registrations.pendingKeys = []
        registrations.hasPendingExternalChange = false
        let includesKey = changes.isEmpty && key != nil
        if includesKey, let key {
          changes.append(.key(key))
        }
        guard !changes.isEmpty else { return nil }
        return (changes, Array(registrations.listeners.values), includesKey)
      }
    if let delivery {
      for change in delivery.changes {
        for listener in delivery.listeners {
          listener(change)
        }
      }
      if delivery.includesKey {
        return
      }
    }
    // The listeners may have changed while they were told about what was held back.
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
  static func shared(
    for instance: UInt,
    id: MMKVStore.ID,
    isMultiProcess: Bool
  ) -> MMKVStoreState {
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

  /// Records an external change to every instance of a store with the identifier `id`. The C++
  /// core reports a change by identifier alone, so stores with the same identifier in different
  /// directories are over-notified, which only costs a spurious `.external`.
  static func markExternalChange(id: String) {
    let states = Self.all.withLock { states in
      states.values.filter { $0.id.rawValue == id }
    }
    for state in states {
      state.markExternalChange()
    }
  }
}
