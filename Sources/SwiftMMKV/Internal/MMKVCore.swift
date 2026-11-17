/// One open instance of a store, and the state shared by every ``MMKVStore`` over it.
///
/// The public types hold one of these privately, so that none of them needs a member that is
/// visible to the rest of the module. Every operation goes to ``engine``, the C++ core or the
/// Swift core that is replacing it, through the store's suspension gate. Nothing here notifies
/// listeners about writes; that is left to ``MMKVStore``.
struct MMKVCore: Sendable {
  let engine: any MMKVEngine
  let state: MMKVStoreState

  /// Opens the instance described by `configuration`, creating its files if they do not exist.
  init(_ configuration: MMKVConfiguration) throws(MMKVError) {
    if let encryption = configuration.encryption, !encryption.isValid {
      throw .invalidEncryptionKey
    }
    let engine: any MMKVEngine =
      switch configuration.engine {
      case .cxx: try CxxEngine(configuration)
      case .swift: try SwiftEngine(configuration)
      }
    self.engine = engine
    self.state = MMKVStoreState.shared(
      for: engine.instance,
      id: configuration.id,
      isMultiProcess: configuration.mode == .multiProcess
    )
  }

  /// Runs an operation that takes the store's file lock, unless the store is suspended.
  ///
  /// - Returns: `nil`, without running `body`, if the store is suspended.
  private func perform<R, E: Error>(
    _ body: (any MMKVEngine) throws(E) -> R
  ) throws(E) -> R? {
    guard let gate = self.state.suspensionGate else { return try body(self.engine) }
    guard gate.enter() else { return nil }
    defer { gate.leave() }
    return try body(self.engine)
  }

  /// Tells listeners about anything the engine noticed while it held its locks. Called once an
  /// operation has returned.
  func operationDidFinish() {
    self.state.deliverPendingExternalChange()
  }
}

// MARK: - Reads

extension MMKVCore {
  func bool(forKey key: String) -> Bool? {
    self.perform { $0.bool(forKey: key) } ?? nil
  }

  func int32(forKey key: String) -> Int32? {
    self.perform { $0.int32(forKey: key) } ?? nil
  }

  func uint32(forKey key: String) -> UInt32? {
    self.perform { $0.uint32(forKey: key) } ?? nil
  }

  func int64(forKey key: String) -> Int64? {
    self.perform { $0.int64(forKey: key) } ?? nil
  }

  func uint64(forKey key: String) -> UInt64? {
    self.perform { $0.uint64(forKey: key) } ?? nil
  }

  func float(forKey key: String) -> Float? {
    self.perform { $0.float(forKey: key) } ?? nil
  }

  func double(forKey key: String) -> Double? {
    self.perform { $0.double(forKey: key) } ?? nil
  }

  func string(forKey key: String) -> String? {
    self.perform { $0.string(forKey: key) } ?? nil
  }

  func strings(forKey key: String) -> [String]? {
    self.perform { $0.strings(forKey: key) } ?? nil
  }

  func withBytes<R, E: Error>(
    forKey key: String,
    _ body: (RawSpan) throws(E) -> R
  ) throws(E) -> R? {
    try self.perform { (engine) throws(E) -> R? in try engine.withBytes(forKey: key, body) } ?? nil
  }
}

// MARK: - Writes

extension MMKVCore {
  func set(_ value: Bool, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    self.perform { $0.set(value, forKey: key, expiresInSeconds: expiresInSeconds) } ?? false
  }

  func set(_ value: Int32, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    self.perform { $0.set(value, forKey: key, expiresInSeconds: expiresInSeconds) } ?? false
  }

  func set(_ value: UInt32, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    self.perform { $0.set(value, forKey: key, expiresInSeconds: expiresInSeconds) } ?? false
  }

  func set(_ value: Int64, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    self.perform { $0.set(value, forKey: key, expiresInSeconds: expiresInSeconds) } ?? false
  }

  func set(_ value: UInt64, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    self.perform { $0.set(value, forKey: key, expiresInSeconds: expiresInSeconds) } ?? false
  }

  func set(_ value: Float, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    self.perform { $0.set(value, forKey: key, expiresInSeconds: expiresInSeconds) } ?? false
  }

  func set(_ value: Double, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    self.perform { $0.set(value, forKey: key, expiresInSeconds: expiresInSeconds) } ?? false
  }

  func set(_ value: String, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    self.perform { $0.set(value, forKey: key, expiresInSeconds: expiresInSeconds) } ?? false
  }

  func set(_ value: [String], forKey key: String, expiresInSeconds: UInt32) -> Bool {
    self.perform { $0.set(value, forKey: key, expiresInSeconds: expiresInSeconds) } ?? false
  }

  func set(bytes: RawSpan, forKey key: String, expiresInSeconds: UInt32) -> Bool {
    self.perform { $0.set(bytes: bytes, forKey: key, expiresInSeconds: expiresInSeconds) }
      ?? false
  }
}

// MARK: - Keys

extension MMKVCore {
  var count: Int {
    self.perform { $0.count } ?? 0
  }

  var keys: Set<String> {
    self.perform { $0.keys } ?? []
  }

  func contains(_ key: String) -> Bool {
    self.perform { $0.contains(key) } ?? false
  }

  func remove(_ key: String) -> Bool {
    self.perform { $0.remove(key) } ?? false
  }

  func remove(_ keys: [String]) {
    guard !keys.isEmpty else { return }
    self.perform { $0.remove(keys) }
  }

  func removeAll(keepingCapacity: Bool) {
    self.perform { $0.removeAll(keepingCapacity: keepingCapacity) }
  }
}

// MARK: - Import

extension MMKVCore {
  func importAll(from source: MMKVCore) -> Int {
    self.perform { engine in
      source.perform { engine.importAll(from: $0) } ?? 0
    } ?? 0
  }
}

// MARK: - Suspension

extension MMKVCore {
  var isSuspended: Bool {
    self.state.suspensionGate?.isSuspended ?? false
  }

  func suspend() {
    self.state.suspensionGate?.suspend()
  }

  func resume() -> Bool {
    self.state.suspensionGate?.resume() ?? false
  }
}

// MARK: - Locking and maintenance

extension MMKVCore {
  /// Runs `body` with the instance's recursive lock held.
  ///
  /// Listeners are not told about an external change while the lock is held, because a listener
  /// that waits on another thread would deadlock against it. They are told once the outermost
  /// call releases the lock.
  func locked<R, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
    let gate = self.state.suspensionGate
    guard gate?.enter() ?? true else { return try body() }
    self.engine.lock()
    self.state.beginDeferringExternalChanges()
    defer {
      self.state.endDeferringExternalChanges()
      self.engine.unlock()
      gate?.leave()
      self.state.deliverPendingExternalChange()
    }
    return try body()
  }

  var totalSize: Int {
    self.perform { $0.totalSize } ?? 0
  }

  var actualSize: Int {
    self.perform { $0.actualSize } ?? 0
  }

  func checkContentChanged() {
    self.perform { $0.checkContentChanged() }
  }

  func trim() {
    self.perform { $0.trim() }
  }

  func sync() {
    self.perform { $0.sync() }
  }

  func rekey(_ encryption: MMKVConfiguration.Encryption?) throws(MMKVError) {
    if let encryption, !encryption.isValid {
      throw .invalidEncryptionKey
    }
    guard let didRekey = self.perform({ $0.rekey(encryption) }) else {
      throw .storeIsSuspended(id: self.state.id)
    }
    guard didRekey else { throw .rekeyFailed }
  }
}
