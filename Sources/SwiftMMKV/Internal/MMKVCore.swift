/// One open instance of a store, and the state shared by every ``MMKVStore`` over it.
///
/// The public types hold one of these privately, so that none of them needs a member that is
/// visible to the rest of the module. Every operation goes to ``engine``, the C++ core or the
/// Swift core that is replacing it, through the store's suspension gate. Which writes listeners
/// are told about is left to ``MMKVStore``, which names them to ``operationDidFinish(writingTo:)``.
///
/// It is a class so that a value reader or writer can refer to it without copying the engine.
final class MMKVCore: Sendable {
  let engine: any MMKVEngine
  let state: MMKVStoreState

  /// Opens the instance described by `configuration`, creating its files if they do not exist.
  init(_ configuration: MMKVConfiguration) throws(MMKVError) {
    if let encryption = configuration.encryption, !encryption.isValid {
      throw .invalidEncryptionKey
    }
    LogSink.prepare()
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

  /// Runs a read that takes the store's file lock.
  ///
  /// - Returns: The result of `body`, or `nil`, as for a key with no value, if the store is
  ///   suspended.
  func read<R, E: Error>(_ body: (any MMKVEngine) throws(E) -> R?) throws(E) -> R? {
    try self.perform(body) ?? nil
  }

  /// Runs a write that takes the store's file lock.
  ///
  /// - Returns: The result of `body`, or `false` if the store is suspended.
  func write(_ body: (any MMKVEngine) -> Bool) -> Bool {
    self.perform(body) ?? false
  }

  /// Tells listeners about anything the engine noticed while it held its locks, and then about
  /// the write to `key` if the operation made one. Called once an operation has returned.
  func operationDidFinish(writingTo key: String? = nil) {
    self.state.deliverChanges(afterWritingTo: key)
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
    self.write { $0.remove(key) }
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
  /// Listeners are not told about a change while the lock is held: about an external one because
  /// a listener that waits on another thread would deadlock against it, and about a key so that
  /// they never see part of what `body` writes. They are told once the outermost call releases
  /// the lock.
  ///
  /// While the store is suspended `body` runs without the lock, and every operation in it is
  /// turned away.
  func locked<R, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
    let gate = self.state.suspensionGate
    guard gate?.enter() ?? true else { return try body() }
    self.engine.lock()
    self.state.beginDeferringChanges()
    defer {
      self.state.endDeferringChanges()
      self.engine.unlock()
      gate?.leave()
      self.state.deliverChanges()
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
