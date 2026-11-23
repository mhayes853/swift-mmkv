/// Tells the process about stores whose files fail a check as they load, as MMKV's
/// `onMMKVCRCCheckFail` and `onMMKVFileLengthError` handlers do.
package enum IntegrityFailureReport {
  package enum Kind: Sendable {
    /// Neither the data's checksum nor its last confirmed one matches the data.
    case checksum
    /// The data is recorded as longer than its file.
    case fileLength
    /// The data matches its checksum but cannot be decoded with the store's encryption key. The
    /// C++ core has no such report.
    case wrongEncryptionKey
  }

  package typealias Handler = @Sendable (_ id: String, _ kind: Kind) -> Void

  private static let lock = ThreadLock()
  nonisolated(unsafe) private static var handler: Handler?

  /// Sets what is called for every failure in the process, with the failing store's locks held.
  package static func setHandler(_ handler: Handler?) {
    Self.lock.withLock { Self.handler = handler }
  }

  static func send(id: String, kind: Kind) {
    Self.lock.withLock { Self.handler }?(id, kind)
  }
}
