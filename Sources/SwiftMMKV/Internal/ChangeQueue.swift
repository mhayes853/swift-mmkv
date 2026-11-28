/// Changes waiting to be delivered, merged so that at most one batch of each kind waits.
///
/// Waiting local keys become one ``MMKVStore/ChangeBatch/Kind/localKeys(_:)`` batch, and
/// waiting external keys one ``MMKVStore/ChangeBatch/Kind/externalKeys(_:)`` batch, each with
/// its keys once, in the order they first changed. A whole-store change waits once for each
/// reason, and makes the external keys that wait with it redundant, since it already says any
/// key may have changed. Local keys are never dropped, so a listener always learns of each key
/// this process wrote. So however much is waiting, it holds each key of the store at most
/// twice.
///
/// The batches keep the order in which the first of each was added.
struct ChangeQueue: Sendable {
  typealias Kind = MMKVStore.ChangeBatch.Kind

  private var kinds = [Kind]()
  /// The keys of the waiting local and external batches, for telling whether a key is already
  /// among them.
  private var localKeys = Set<String>()
  private var externalKeys = Set<String>()

  var isEmpty: Bool {
    self.kinds.isEmpty
  }

  mutating func add(_ kind: Kind) {
    switch kind {
    case .localKeys(let keys):
      let new = keys.filter { self.localKeys.insert($0).inserted }
      self.merge(new, into: .localKeys)

    case .externalKeys(let keys):
      guard !self.kinds.contains(where: \.isWholeStore) else { return }
      let new = keys.filter { self.externalKeys.insert($0).inserted }
      self.merge(new, into: .externalKeys)

    case .wholeStore:
      guard !self.kinds.contains(kind) else { return }
      self.kinds.removeAll { $0.origin == .externalKeys }
      self.externalKeys = []
      self.kinds.append(kind)
    }
  }

  /// Adds `keys`, none of them waiting yet, to the waiting batch of `origin`, or waits with a
  /// new batch of them.
  private mutating func merge(_ keys: [String], into origin: KeyOrigin) {
    guard !keys.isEmpty else { return }
    func make(_ keys: [String]) -> Kind {
      switch origin {
      case .localKeys: .localKeys(keys)
      case .externalKeys: .externalKeys(keys)
      }
    }
    guard let index = self.kinds.firstIndex(where: { $0.origin == origin }) else {
      self.kinds.append(make(keys))
      return
    }
    switch self.kinds[index] {
    case .localKeys(let waiting), .externalKeys(let waiting):
      self.kinds[index] = make(waiting + keys)
    case .wholeStore:
      break
    }
  }

  /// Removes and returns the batch that has waited longest.
  mutating func removeFirst() -> Kind? {
    guard !self.kinds.isEmpty else { return nil }
    let kind = self.kinds.removeFirst()
    switch kind {
    case .localKeys: self.localKeys = []
    case .externalKeys: self.externalKeys = []
    case .wholeStore: break
    }
    return kind
  }

  /// Removes and returns every waiting batch.
  mutating func removeAll() -> [Kind] {
    defer { self = ChangeQueue() }
    return self.kinds
  }
}

/// Which of the batches that name keys a batch is.
private enum KeyOrigin {
  case localKeys
  case externalKeys
}

extension MMKVStore.ChangeBatch.Kind {
  fileprivate var isWholeStore: Bool {
    if case .wholeStore = self { true } else { false }
  }

  fileprivate var origin: KeyOrigin? {
    switch self {
    case .localKeys: .localKeys
    case .externalKeys: .externalKeys
    case .wholeStore: nil
    }
  }
}
