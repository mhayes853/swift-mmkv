// The index of an encrypted store: each key's entry (MMKV's `m_dicCrypt`).
//
// An encrypted record's key is ciphertext in the file, so unlike ``RecordIndex`` this index keeps
// its keys. The C++ core keeps each key in a `std::string` and each small value in a buffer of its
// own. This keeps every key, and every value kept in memory, in one arena: a single growing block
// of bytes, compacted when enough of it belongs to entries since replaced or removed. Each key
// takes one 20-byte slot of a ``SlotTable`` besides its bytes in the arena.

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Android)
  import Android
#endif

/// An encrypted store's index entry (`KeyValueHolderCrypt`).
enum CryptEntry {
  /// A value of up to 256 bytes, decrypted, in the index's arena: valid until the index next
  /// changes. `order` is where its record was, which the C++ core does not keep; the Swift core
  /// uses it to write these values back in a stable order.
  case memory(value: UnsafeRawBufferPointer, order: UInt32)
  /// A larger value, left in the file.
  case offset(CryptRecord)

  var realValueSize: Int {
    switch self {
    case .memory(let value, _): value.count
    case .offset(let record): Int(record.valueSize)
    }
  }

  var order: UInt32 {
    switch self {
    case .memory(_, let order): order
    case .offset(let record): record.offset
    }
  }

  /// Whether a value of `size` bytes stays in the file (`isValueStoredAsOffset`).
  static func isValueStoredAsOffset(_ size: Int) -> Bool {
    size > 256
  }
}

/// Each key's entry in an encrypted store, with the keys and the values kept in memory in one
/// arena.
struct CryptIndex: ~Copyable {
  struct Slot: HashTableSlot {
    var hash: UInt32
    /// Where the key starts in the arena. A value kept in memory, or a large record's cipher
    /// state, follows it.
    var arenaOffset: UInt32
    var keySize: UInt16
    var isOffset: Bool
    /// The size of a large record's length prefixes.
    var pbKeyValueSize: UInt8
    var valueSize: UInt32
    /// Where the record was, for a value kept in memory, or is, for a large value.
    var position: UInt32

    static var empty: Slot {
      Slot(
        hash: 0,
        arenaOffset: 0,
        keySize: 0,
        isOffset: false,
        pbKeyValueSize: 0,
        valueSize: 0,
        position: 0
      )
    }

    /// The bytes the entry takes in the arena.
    var arenaSize: Int {
      Int(self.keySize) + (self.isOffset ? CryptIndex.stateSize : Int(self.valueSize))
    }
  }

  /// The bytes a cipher state takes in the arena: its register and its position in the block.
  private static let stateSize = 20

  private var table = SlotTable<Slot>()
  private var arena: UnsafeMutableRawPointer?
  private var arenaCapacity = 0
  /// How much of the arena is in use, including garbage.
  private var arenaUsed = 0
  /// How much of the arena belongs to entries since replaced or removed.
  private var arenaGarbage = 0

  init() {}

  deinit {
    free(self.arena)
  }

  var count: Int {
    self.table.count
  }

  var isEmpty: Bool {
    self.table.count == 0
  }

  // MARK: Lookup

  private func probe(_ key: UnsafeRawBufferPointer, hash: UInt32) -> HashProbe {
    let arena = self.arena
    return self.table.probe(hash: hash) { slot in
      guard Int(slot.keySize) == key.count else { return false }
      guard key.count > 0 else { return true }
      return memcmp(arena! + Int(slot.arenaOffset), key.baseAddress!, key.count) == 0
    }
  }

  func slot(of key: UnsafeRawBufferPointer) -> Int? {
    guard self.table.count > 0 else { return nil }
    if case .found(let slot) = self.probe(key, hash: self.table.hash(key)) {
      return slot
    }
    return nil
  }

  func entry(of key: UnsafeRawBufferPointer) -> CryptEntry? {
    self.slot(of: key).map { self.entry(at: $0) }
  }

  func contains(_ key: UnsafeRawBufferPointer) -> Bool {
    self.slot(of: key) != nil
  }

  /// The key in `slot`, valid until the index next changes.
  func key(at slot: Int) -> UnsafeRawBufferPointer {
    let slot = self.table[slot]
    return UnsafeRawBufferPointer(
      start: self.arena! + Int(slot.arenaOffset),
      count: Int(slot.keySize)
    )
  }

  func entry(at index: Int) -> CryptEntry {
    Self.entry(self.table[index], arena: self.arena)
  }

  private static func entry(_ slot: Slot, arena: UnsafeMutableRawPointer?) -> CryptEntry {
    let payload = arena.map { $0 + Int(slot.arenaOffset) + Int(slot.keySize) }
    if slot.isOffset {
      var state = CipherState(vector: payload!, number: 0)
      state.number = payload!.loadUnaligned(fromByteOffset: 16, as: UInt32.self)
      return .offset(
        CryptRecord(
          offset: slot.position,
          keySize: slot.keySize,
          valueSize: slot.valueSize,
          pbKeyValueSize: slot.pbKeyValueSize,
          state: state
        )
      )
    }
    return .memory(
      value: UnsafeRawBufferPointer(start: payload, count: Int(slot.valueSize)),
      order: slot.position
    )
  }

  // MARK: Adding and removing

  /// Keeps `value` in memory as `key`'s, from a record at `order`.
  mutating func setValue(
    _ value: UnsafeRawBufferPointer,
    order: UInt32,
    for key: UnsafeRawBufferPointer
  ) {
    var slot = Slot.empty
    slot.keySize = UInt16(truncatingIfNeeded: key.count)
    slot.valueSize = UInt32(truncatingIfNeeded: value.count)
    slot.position = order
    self.set(slot, key: key, payload: value)
  }

  /// Records that `key`'s value is the large one in `record`.
  mutating func setRecord(_ record: CryptRecord, for key: UnsafeRawBufferPointer) {
    withUnsafeBytes(of: Self.stateBytes(record.state)) { state in
      self.set(Self.slot(for: record), key: key, payload: state)
    }
  }

  /// Moves the large record of the key in `index`.
  mutating func setRecord(_ record: CryptRecord, at index: Int) {
    var slot = Self.slot(for: record)
    slot.hash = self.table[index].hash
    slot.arenaOffset = self.table[index].arenaOffset
    self.table[index] = slot
    withUnsafeBytes(of: Self.stateBytes(record.state)) { state in
      (self.arena! + Int(slot.arenaOffset) + Int(slot.keySize))
        .copyMemory(
          from: state.baseAddress!,
          byteCount: Self.stateSize
        )
    }
  }

  private static func slot(for record: CryptRecord) -> Slot {
    Slot(
      hash: 0,
      arenaOffset: 0,
      keySize: record.keySize,
      isOffset: true,
      pbKeyValueSize: record.pbKeyValueSize,
      valueSize: record.valueSize,
      position: record.offset
    )
  }

  private static func stateBytes(_ state: CipherState) -> (UInt64, UInt64, UInt32) {
    (state.register.0, state.register.1, state.number)
  }

  /// Records `slot` for `key`, with `payload` after the key in the arena.
  private mutating func set(
    _ slot: Slot,
    key: UnsafeRawBufferPointer,
    payload: UnsafeRawBufferPointer
  ) {
    var slot = slot
    slot.hash = self.table.hash(key)
    let probe = self.probe(key, hash: slot.hash)
    let payload = UnsafeRawBufferPointer(
      rebasing: payload.prefix(slot.isOffset ? Self.stateSize : payload.count)
    )
    let size = key.count + payload.count
    if case .found(let index) = probe, self.table[index].arenaSize == size {
      // The same size as before: overwrite it in place.
      slot.arenaOffset = self.table[index].arenaOffset
      self.write(payload, at: Int(slot.arenaOffset) + key.count)
      self.table[index] = slot
      return
    }
    slot.arenaOffset = UInt32(truncatingIfNeeded: self.append(key, payload))
    switch probe {
    case .found(let index):
      self.arenaGarbage += self.table[index].arenaSize
      self.table[index] = slot
    case .vacant(let index):
      self.table.insert(slot, at: index)
    }
    self.compactIfNeeded()
  }

  /// Removes `key`.
  ///
  /// - Returns: Whether the key was in the index.
  @discardableResult
  mutating func remove(_ key: UnsafeRawBufferPointer) -> Bool {
    guard let index = self.slot(of: key) else { return false }
    self.arenaGarbage += self.table[index].arenaSize
    self.table.remove(at: index)
    self.compactIfNeeded()
    return true
  }

  /// Removes every key whose entry satisfies `shouldRemove`.
  ///
  /// - Returns: How many keys were removed.
  @discardableResult
  mutating func removeAll(where shouldRemove: (CryptEntry) -> Bool) -> Int {
    let arena = self.arena
    var garbage = 0
    let removed = self.table.removeAll { slot in
      guard shouldRemove(Self.entry(slot, arena: arena)) else { return false }
      garbage += slot.arenaSize
      return true
    }
    self.arenaGarbage += garbage
    self.compactIfNeeded()
    return removed
  }

  /// Removes every key and gives back the index's memory.
  mutating func removeAll() {
    self.table.removeAll()
    free(self.arena)
    self.arena = nil
    self.arenaCapacity = 0
    self.arenaUsed = 0
    self.arenaGarbage = 0
  }

  // MARK: Enumeration

  /// Calls `body` with every occupied slot and its entry, in no particular order.
  func forEachEntry<E: Error>(_ body: (Int, CryptEntry) throws(E) -> Void) throws(E) {
    let arena = self.arena
    try self.table.forEachSlot { (index, slot) throws(E) in
      try body(index, Self.entry(slot, arena: arena))
    }
  }

  /// The occupied slots, ordered by where their records are or were.
  func slotsInRecordOrder() -> LazyMapSequence<[UInt64], Int> {
    self.table.slotIndices { $0.position }
  }

  // MARK: The arena

  private func write(_ bytes: UnsafeRawBufferPointer, at offset: Int) {
    guard let source = bytes.baseAddress, bytes.count > 0 else { return }
    // The bytes may come from the arena itself.
    memmove(self.arena! + offset, source, bytes.count)
  }

  /// Adds `key` followed by `payload` to the end of the arena.
  ///
  /// - Returns: Where they start.
  private mutating func append(
    _ key: UnsafeRawBufferPointer,
    _ payload: UnsafeRawBufferPointer
  ) -> Int {
    let size = key.count + payload.count
    var key = key
    var payload = payload
    if self.arenaUsed + size > self.arenaCapacity {
      // The bytes may be in the arena already, as when a value read from the index is written
      // back, so they are found again after it moves.
      let keyOffset = self.offsetInArena(key)
      let payloadOffset = self.offsetInArena(payload)
      var capacity = max(self.arenaCapacity, 256)
      while capacity < self.arenaUsed + size {
        capacity *= 2
      }
      self.resizeArena(to: capacity)
      if let keyOffset {
        key = UnsafeRawBufferPointer(start: self.arena! + keyOffset, count: key.count)
      }
      if let payloadOffset {
        payload = UnsafeRawBufferPointer(start: self.arena! + payloadOffset, count: payload.count)
      }
    }
    let start = self.arenaUsed
    self.write(key, at: start)
    self.write(payload, at: start + key.count)
    self.arenaUsed += size
    return start
  }

  private func offsetInArena(_ bytes: UnsafeRawBufferPointer) -> Int? {
    guard let arena = self.arena, let start = bytes.baseAddress else { return nil }
    let offset = start - UnsafeRawPointer(arena)
    return offset >= 0 && offset < self.arenaCapacity ? offset : nil
  }

  /// Moves the arena into a block of `capacity` bytes, with `realloc`, which can often resize a
  /// large block where it is rather than copy it.
  private mutating func resizeArena(to capacity: Int) {
    guard let arena = realloc(self.arena, capacity) else {
      fatalError("cannot allocate \(capacity) bytes for an encrypted store's index")
    }
    self.arena = arena
    self.arenaCapacity = capacity
  }

  /// Makes room in the arena for `byteCount` bytes of keys and values without growing again. A
  /// large block's memory is only used once it is written, so reserving more than the entries
  /// turn out to need costs little until ``shrinkArenaToFit()``.
  mutating func reserveArena(_ byteCount: Int) {
    if byteCount > self.arenaCapacity {
      self.resizeArena(to: byteCount)
    }
  }

  /// Gives back the arena's memory that its entries do not use.
  mutating func shrinkArenaToFit() {
    let capacity = max(self.arenaUsed, 256)
    if capacity < self.arenaCapacity {
      self.resizeArena(to: capacity)
    }
  }

  /// Moves the live entries to the start of the arena once garbage is half of it, and gives back
  /// what the arena no longer needs.
  private mutating func compactIfNeeded() {
    guard self.arenaGarbage > 4096, self.arenaGarbage * 2 > self.arenaUsed, let arena = self.arena
    else { return }
    var used = 0
    for index in self.table.slotIndices(orderedBy: { $0.arenaOffset }) {
      var slot = self.table[index]
      let size = slot.arenaSize
      if Int(slot.arenaOffset) != used {
        // Entries only move towards the start, so none is overwritten before it moves.
        memmove(arena + used, arena + Int(slot.arenaOffset), size)
        slot.arenaOffset = UInt32(used)
        self.table[index] = slot
      }
      used += size
    }
    self.arenaUsed = used
    self.arenaGarbage = 0
    if self.arenaCapacity > 4 * max(used, 256) {
      self.resizeArena(to: max(used * 2, 256))
    }
  }
}
