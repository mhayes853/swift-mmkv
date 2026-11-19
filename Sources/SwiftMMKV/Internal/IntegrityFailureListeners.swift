import CSwiftMMKVCore

/// The process-wide listeners for ``MMKVStore/IntegrityFailure``.
enum IntegrityFailureListeners {
  typealias Listener = @Sendable (MMKVStore.IntegrityFailure) -> Void

  private struct Registrations {
    var listeners = [Int: Listener]()
    var nextIdentifier = 0
  }

  private static let registrations = Lock(Registrations())

  static func add(_ listener: @escaping Listener) -> MMKVSubscription {
    _ = self.installCallback
    let identifier = self.registrations.withLock { registrations in
      defer { registrations.nextIdentifier &+= 1 }
      registrations.listeners[registrations.nextIdentifier] = listener
      return registrations.nextIdentifier
    }
    return MMKVSubscription {
      self.registrations.withLock { _ = $0.listeners.removeValue(forKey: identifier) }
    }
  }

  private static let installCallback: Void = {
    mmkv_set_integrity_failure_callback { id, kind in
      let failure = MMKVStore.IntegrityFailure(
        id: MMKVStore.ID(
          rawValue: String(
            decoding: UnsafeRawBufferPointer(start: id.bytes, count: id.count),
            as: UTF8.self
          )
        ),
        kind: kind == MMKV_INTEGRITY_FAILURE_FILE_LENGTH ? .fileLength : .checksum
      )
      let listeners = IntegrityFailureListeners.registrations.withLock {
        Array($0.listeners.values)
      }
      for listener in listeners {
        listener(failure)
      }
    }
  }()
}
