import CSwiftMMKVCore
import _SwiftMMKVCore

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

  /// Has both cores report to the listeners.
  private static let installCallback: Void = {
    mmkv_set_integrity_failure_callback { id, kind in
      let id = String(
        decoding: UnsafeRawBufferPointer(start: id.bytes, count: id.count),
        as: UTF8.self
      )
      IntegrityFailureListeners.send(
        id: id,
        kind: kind == MMKV_INTEGRITY_FAILURE_FILE_LENGTH ? .fileLength : .checksum
      )
    }
    IntegrityFailureReport.setHandler { id, kind in
      let kind: MMKVStore.IntegrityFailure.Kind =
        switch kind {
        case .checksum: .checksum
        case .fileLength: .fileLength
        case .wrongEncryptionKey: .wrongEncryptionKey
        }
      IntegrityFailureListeners.send(id: id, kind: kind)
    }
  }()

  private static func send(id: String, kind: MMKVStore.IntegrityFailure.Kind) {
    let failure = MMKVStore.IntegrityFailure(id: MMKVStore.ID(rawValue: id), kind: kind)
    let listeners = self.registrations.withLock { Array($0.listeners.values) }
    for listener in listeners {
      listener(failure)
    }
  }
}
