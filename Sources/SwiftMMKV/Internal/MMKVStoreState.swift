import CSwiftMMKVCore

/// The listeners and pending notifications of one underlying MMKV instance.
///
/// The core hands back the same instance for every open of a root directory and identifier, so
/// this is shared by every ``MMKVStore`` over that instance.
final class MMKVStoreState: Sendable {
  /// Called with what one operation changed. Changes that are held back while the store is
  /// locked arrive together, once it is unlocked.
  typealias Listener = @Sendable (StoreChanges) -> Void

  private struct Registrations: Sendable {
    var nextIdentifier: UInt64 = 0
    var listeners = [UInt64: Listener]()
    var hasPendingExternalChange = false
    var pendingKeys = [String]()
    var deferralDepth = 0
  }

  let id: MMKVStore.ID
  /// Turns operations away while the store is suspended, and once it is closed.
  let gate = StoreGate()
  /// A single-process store takes no file lock, so it has nothing to suspend.
  let canSuspend: Bool
  /// Shared by every store over the instance, so that suspending one tells the observers of
  /// them all. A registrar tells observers apart by key path, and not by which store was read.
  let observationRegistrar = _ObservationRegistrar()
  private let registrations = Lock(Registrations())

  private init(id: MMKVStore.ID, isMultiProcess: Bool) {
    self.id = id
    self.canSuspend = isMultiProcess
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

  /// Tells listeners that an operation changed `key`, or holds that back while changes are
  /// being deferred. A key that is changed more than once in that time is reported once.
  func notify(key: String) {
    self.notify(StoreChanges(keys: [key], isExternal: false))
  }

  /// Tells listeners that one operation changed `keys`, together, or holds that back while
  /// changes are being deferred.
  func notify(keys: [String]) {
    var seen = Set<String>()
    self.notify(StoreChanges(keys: keys.filter { seen.insert($0).inserted }, isExternal: false))
  }

  /// Tells listeners that the store was changed from outside this package, or holds that back
  /// while changes are being deferred.
  func notifyExternalChange() {
    self.notify(StoreChanges(keys: [], isExternal: true))
  }

  private func notify(_ changes: StoreChanges) {
    guard !changes.isEmpty else { return }
    let listeners: [Listener]? = self.registrations.withLock { registrations in
      guard registrations.deferralDepth > 0 else { return Array(registrations.listeners.values) }
      for key in changes.keys where !registrations.pendingKeys.contains(key) {
        registrations.pendingKeys.append(key)
      }
      if changes.isExternal {
        registrations.hasPendingExternalChange = true
      }
      return nil
    }
    guard let listeners else { return }
    for listener in listeners {
      listener(changes)
    }
  }

  /// Tells listeners that the store changed, for the last time, and forgets them along with
  /// anything that was being held back for them. Called once the store is closed.
  func finishListeners() {
    let listeners = self.registrations.withLock { registrations in
      defer {
        registrations.listeners = [:]
        registrations.pendingKeys = []
        registrations.hasPendingExternalChange = false
      }
      return Array(registrations.listeners.values)
    }
    for listener in listeners {
      listener(StoreChanges(keys: [], isExternal: true))
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
    let pending: (changes: StoreChanges, listeners: [Listener])? =
      self.registrations.withLock { registrations in
        guard registrations.deferralDepth == 0 else { return nil }
        let changes = StoreChanges(
          keys: registrations.pendingKeys,
          isExternal: registrations.hasPendingExternalChange
        )
        guard !changes.isEmpty else { return nil }
        registrations.pendingKeys = []
        registrations.hasPendingExternalChange = false
        return (changes, Array(registrations.listeners.values))
      }
    guard let pending else { return }
    for listener in pending.listeners {
      listener(pending.changes)
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

  /// Forgets the state of the instance whose pointer has these bits, which is about to be freed.
  /// A later instance may be given the same pointer.
  static func remove(forHandle handle: UInt) {
    Self.all.withLock { _ = $0.removeValue(forKey: handle) }
  }

  /// The state of the instance whose pointer has these bits, if a store has been made over it.
  static func existing(forHandle handle: UInt) -> MMKVStoreState? {
    Self.all.withLock { $0[handle] }
  }

  // The core reports a change by store identifier alone, so every state with that identifier is
  // marked. Stores with the same identifier in different directories are over-notified, which
  // only costs a spurious external change.
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

/// What one operation changed in a store, before it is tied to the store a listener subscribed
/// through.
struct StoreChanges: Sendable {
  /// The keys set or removed, each once, in order.
  var keys: [String]
  /// Whether the store was changed from outside this package.
  var isExternal: Bool

  var isEmpty: Bool {
    self.keys.isEmpty && !self.isExternal
  }
}
