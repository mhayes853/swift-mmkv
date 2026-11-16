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
    var deferralDepth = 0
  }

  let id: String
  private let registrations = Lock(Registrations())

  private init(id: String) {
    self.id = id
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

  /// Records that the core saw the store's file change underneath it. Called with the core's
  /// locks held, so listeners are told later, by ``deliverPendingExternalChange()``.
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
  /// unless changes are being deferred.
  func deliverPendingExternalChange() {
    let listeners: [Listener]? = self.registrations.withLock { registrations in
      guard registrations.hasPendingExternalChange, registrations.deferralDepth == 0 else {
        return nil
      }
      registrations.hasPendingExternalChange = false
      return Array(registrations.listeners.values)
    }
    guard let listeners else { return }
    for listener in listeners {
      listener(.external)
    }
  }
}

extension MMKVStoreState {
  private static let all = Lock([UInt: MMKVStoreState]())

  /// Returns the state shared by every store over `handle`.
  static func shared(for handle: OpaquePointer, id: String) -> MMKVStoreState {
    Self.installContentChangedCallback
    return Self.all.withLock { states in
      let key = UInt(bitPattern: handle)
      if let state = states[key] {
        return state
      }
      let state = MMKVStoreState(id: id)
      states[key] = state
      return state
    }
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
        states.values.filter { $0.id == id }
      }
      for state in states {
        state.markExternalChange()
      }
    }
  }()
}
