// The index of a plain-text store: where each key's latest record is (MMKV's `m_dic`).
//
// The C++ core keeps a `std::unordered_map` from a copy of each key to its record. This keeps no
// keys at all. A plain-text record starts with its key, so the index only records where each
// record is, together with a hash of its key, and compares a key against the record's bytes in the
// mapped file. Each key takes one 16-byte slot of a ``SlotTable``.

/// Where each key's latest record is in a block of records, as a hash table whose keys are read
/// from the records themselves.
///
/// Every operation that compares keys takes `base`, the start of the data the locations are
/// measured from. The caller keeps the records at every location in place, or moves them and
/// updates their locations with ``setLocation(_:at:)``, which keeps each key's slot.
package struct RecordIndex: ~Copyable {
  struct Slot: HashTableSlot {
    var hash: UInt32
    var location: RecordLocation

    static var empty: Slot {
      Slot(
        hash: 0,
        location: RecordLocation(computedKVSize: 0, keySize: 0, valueSize: 0, offset: 0)
      )
    }
  }

  package typealias Probe = HashProbe

  private var table = SlotTable<Slot>()

  package init() {}

  package var count: Int {
    self.table.count
  }

  package var isEmpty: Bool {
    self.table.count == 0
  }

  /// Changes whenever a key is added or removed, so that a caller holding a slot number can tell
  /// whether it still refers to the same key.
  package var version: Int {
    self.table.version
  }

  // MARK: Keys

  /// The hash of `key` in this index.
  package func hash(_ key: UnsafeRawBufferPointer) -> UInt32 {
    self.table.hash(key)
  }

  /// The bytes of the key of the record at `location`.
  package static func key(at location: RecordLocation, in base: UnsafeRawPointer)
    -> UnsafeRawBufferPointer
  {
    let start = Int(location.offset) + pbRawVarint32Size(UInt32(location.keySize))
    return UnsafeRawBufferPointer(start: base + start, count: Int(location.keySize))
  }

  /// The bytes of the value of the record at `location`.
  package static func value(at location: RecordLocation, in base: UnsafeRawPointer)
    -> UnsafeRawBufferPointer
  {
    UnsafeRawBufferPointer(start: base + location.valueOffset, count: Int(location.valueSize))
  }

  private static func matches(
    _ key: UnsafeRawBufferPointer,
    _ location: RecordLocation,
    _ base: UnsafeRawPointer?
  ) -> Bool {
    guard Int(location.keySize) == key.count else { return false }
    guard key.count > 0 else { return true }
    guard let base, let keyStart = key.baseAddress else { return false }
    return memcmp(Self.key(at: location, in: base).baseAddress!, keyStart, key.count) == 0
  }

  // MARK: Lookup

  /// Finds `key`, whose hash is `hash`.
  package func probe(_ key: UnsafeRawBufferPointer, hash: UInt32, base: UnsafeRawPointer?) -> Probe
  {
    self.table.probe(hash: hash) { Self.matches(key, $0.location, base) }
  }

  /// The slot holding `key`, if it is in the index.
  package func slot(of key: UnsafeRawBufferPointer, base: UnsafeRawPointer?) -> Int? {
    guard self.table.count > 0 else { return nil }
    if case .found(let slot) = self.probe(key, hash: self.hash(key), base: base) {
      return slot
    }
    return nil
  }

  package func location(of key: UnsafeRawBufferPointer, base: UnsafeRawPointer?)
    -> RecordLocation?
  {
    self.slot(of: key, base: base).map { self.table[$0].location }
  }

  package func location(at slot: Int) -> RecordLocation {
    self.table[slot].location
  }

  /// Moves the record in `slot`, which keeps its key.
  package mutating func setLocation(_ location: RecordLocation, at slot: Int) {
    self.table[slot].location = location
  }

  // MARK: Adding and removing

  /// Records `location` as `key`'s, whether or not the key is in the index.
  package mutating func set(
    _ location: RecordLocation,
    for key: UnsafeRawBufferPointer,
    base: UnsafeRawPointer?
  ) {
    let hash = self.hash(key)
    switch self.probe(key, hash: hash, base: base) {
    case .found(let slot):
      self.table[slot].location = location
    case .vacant(let slot):
      self.insert(location, hash: hash, at: slot)
    }
  }

  /// Adds a key whose ``probe(_:hash:base:)`` returned `.vacant(slot)`, with nothing added or
  /// removed since.
  package mutating func insert(_ location: RecordLocation, hash: UInt32, at slot: Int) {
    self.table.insert(Slot(hash: hash, location: location), at: slot)
  }

  @discardableResult
  package mutating func remove(_ key: UnsafeRawBufferPointer, base: UnsafeRawPointer?)
    -> RecordLocation?
  {
    guard let slot = self.slot(of: key, base: base) else { return nil }
    let location = self.table[slot].location
    self.table.remove(at: slot)
    return location
  }

  package mutating func remove(at slot: Int) {
    self.table.remove(at: slot)
  }

  /// Removes every key whose location satisfies `shouldRemove`.
  ///
  /// - Returns: How many keys were removed.
  @discardableResult
  package mutating func removeAll(where shouldRemove: (RecordLocation) -> Bool) -> Int {
    self.table.removeAll { shouldRemove($0.location) }
  }

  /// Removes every key and gives back the table's memory.
  package mutating func removeAll() {
    self.table.removeAll()
  }

  /// Makes room for `count` keys without growing again.
  package mutating func reserveCapacity(_ count: Int) {
    self.table.reserveCapacity(count)
  }

  /// Gives back memory the keys no longer need, after many have been removed or were found to be
  /// overwrites of the same key.
  package mutating func shrinkToFit() {
    self.table.shrinkToFit()
  }

  // MARK: Enumeration

  /// Calls `body` with every occupied slot and its location, in no particular order.
  package func forEachRecord<E: Error>(
    _ body: (Int, RecordLocation) throws(E) -> Void
  ) throws(E) {
    try self.table.forEachSlot { (index, slot) throws(E) in try body(index, slot.location) }
  }

  /// The occupied slots, ordered by where their records are.
  package func slotsInRecordOrder() -> LazyMapSequence<[UInt64], Int> {
    self.table.slotIndices { $0.location.offset }
  }
}
