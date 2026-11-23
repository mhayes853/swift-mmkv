import CSwiftMMKVCore

/// The listeners and pending notifications of one underlying MMKV instance.
///
/// The core hands back the same instance for every open of a root directory and identifier, so
/// this is shared by every ``MMKVStore`` over that instance.
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
  /// Shared by every store over the instance, so that suspending one tells the observers of
  /// them all. A registrar tells observers apart by key path, and not by which store was read.
  let observationRegistrar = _ObservationRegistrar()
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

  /// Records that the core saw the store's file change underneath it. Called with the core's
  /// locks held, so listeners are told later, by ``deliverPendingChanges()``.
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

  /// Tells listeners about the changes that were held back, and about an external change the
  /// core noticed during an earlier operation, unless changes are being deferred.
  func deliverPendingChanges() {
    let pending: (changes: [MMKVStore.Change], listeners: [Listener])? =
      self.registrations.withLock { registrations in
        guard registrations.deferralDepth == 0 else { return nil }
        var changes = registrations.pendingKeys.map(MMKVStore.Change.key)
        if registrations.hasPendingExternalChange {
          changes.append(.external)
        }
        guard !changes.isEmpty else { return nil }
        registrations.pendingKeys = []
        registrations.hasPendingExternalChange = false
        return (changes, Array(registrations.listeners.values))
      }
    guard let pending else { return }
    for change in pending.changes {
      for listener in pending.listeners {
        listener(change)
      }
    }
  }
}

extension MMKVStoreState {
  private static let all = Lock([UInt: MMKVStoreState]())

  /// Returns the state shared by every store over `handle`.
  ///
  /// The first open of an instance decides its mode, as it does in the core.
  static func shared(
    for handle: OpaquePointer,
    id: MMKVStore.ID,
    isMultiProcess: Bool
  ) -> MMKVStoreState {
    Self.installContentChangedCallback
    return Self.all.withLock { states in
      let key = UInt(bitPattern: handle)
      if let state = states[key] {
        return state
      }
      let state = MMKVStoreState(id: id, isMultiProcess: isMultiProcess)
      states[key] = state
      return state
    }
  }

  /// The state of the instance whose pointer has these bits, if a store has been made over it.
  static func existing(forHandle handle: UInt) -> MMKVStoreState? {
    Self.all.withLock { $0[handle] }
  }

  // The core reports a change by store identifier alone, so every state with that identifier is
  // marked. Stores with the same identifier in different directories are over-notified, which
  // only costs a spurious `.external`.
  private static let installContentChangedCallback: Void = {
    mmkv_set_content_changed_callback { id in
      let id = String(
        decoding: UnsafeRawBufferPointer(start: id.bytes, count: id.count),
        as: UTF8.self
      )
      let states = MMKVStoreState.all.withLock { states in
        states.values.filter { $0.id.rawValue == id }
      }
      for state in states {
        state.markExternalChange()
      }
    }
  }()
}
