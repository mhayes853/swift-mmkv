// The index of a plain-text store: where each key's latest record is (MMKV's `m_dic`).
//
// The C++ core keeps a `std::unordered_map` from a copy of each key to its record. This keeps no
// keys at all. A plain-text record starts with its key, so the index only records where each
// record is, together with a hash of its key, and compares a key against the record's bytes in the
// mapped file. The index is an open-addressing hash table with linear probing, whose slots are 16
// bytes each.

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Android)
  import Android
#endif

/// Where each key's latest record is in a block of records, as a hash table whose keys are read
/// from the records themselves.
///
/// Every operation that compares keys takes `base`, the start of the data the locations are
/// measured from. The caller keeps the records at every location in place, or moves them and
/// updates their locations with ``setLocation(_:at:)``, which keeps each key's slot.
package struct RecordIndex: ~Copyable {
  struct Slot {
    /// The key's hash, which is never 0, or 0 for an empty slot.
    var hash: UInt32
    var location: RecordLocation
  }

  /// The result of looking up a key.
  package enum Probe {
    /// The key is in this slot.
    case found(Int)
    /// The key is absent, and would go in this slot.
    case vacant(Int)
  }

  private var slots: UnsafeMutablePointer<Slot>
  /// A power of two, so that a hash's low bits pick a slot.
  private var capacity: Int
  package private(set) var count = 0
  /// Changes whenever a key is added or removed, or the table is resized, so that a caller holding
  /// a slot number can tell whether it still refers to the same key.
  package private(set) var version = 0
  private let seed: UInt64

  private static let minimumCapacity = 16

  package init() {
    self.capacity = Self.minimumCapacity
    self.slots = Self.allocate(self.capacity)
    self.seed = UInt64.random(in: .min ... .max)
  }

  deinit {
    self.slots.deallocate()
  }

  private static func allocate(_ capacity: Int) -> UnsafeMutablePointer<Slot> {
    let slots = UnsafeMutablePointer<Slot>.allocate(capacity: capacity)
    slots.initialize(
      repeating: Slot(
        hash: 0,
        location: RecordLocation(computedKVSize: 0, keySize: 0, valueSize: 0, offset: 0)
      ),
      count: capacity
    )
    return slots
  }

  package var isEmpty: Bool {
    self.count == 0
  }

  // MARK: Keys

  /// The hash of `key` in this index.
  package func hash(_ key: UnsafeRawBufferPointer) -> UInt32 {
    var hash = self.seed ^ (UInt64(key.count) &* 0x9E37_79B9_7F4A_7C15)
    var index = 0
    let count = key.count
    while count - index >= 8 {
      let word = key.loadUnaligned(fromByteOffset: index, as: UInt64.self)
      hash = Self.mix(hash ^ word, 0xA076_1D64_78BD_642F)
      index += 8
    }
    var tail: UInt64 = 0
    var shift: UInt64 = 0
    while index < count {
      tail |= UInt64(key[index]) << shift
      shift += 8
      index += 1
    }
    hash = Self.mix(hash ^ tail, 0xE703_7ED1_A0B4_28DB)
    hash = Self.mix(hash, 0x8EBC_6AF0_9C88_C6E3)
    let folded = UInt32(truncatingIfNeeded: hash ^ (hash >> 32))
    return folded == 0 ? 1 : folded
  }

  private static func mix(_ a: UInt64, _ b: UInt64) -> UInt64 {
    let product = a.multipliedFullWidth(by: b)
    return product.high ^ product.low
  }

  /// The bytes of the key of the record at `location`.
  package static func key(at location: RecordLocation, in base: UnsafeRawPointer)
    -> UnsafeRawBufferPointer
  {
    let start = Int(location.offset) + pbRawVarint32Size(UInt32(location.keySize))
    return UnsafeRawBufferPointer(start: base + start, count: Int(location.keySize))
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
    let mask = self.capacity - 1
    var index = Int(hash) & mask
    while true {
      let slot = self.slots[index]
      if slot.hash == 0 {
        return .vacant(index)
      }
      if slot.hash == hash && Self.matches(key, slot.location, base) {
        return .found(index)
      }
      index = (index + 1) & mask
    }
  }

  /// The slot holding `key`, if it is in the index.
  package func slot(of key: UnsafeRawBufferPointer, base: UnsafeRawPointer?) -> Int? {
    guard self.count > 0 else { return nil }
    if case .found(let slot) = self.probe(key, hash: self.hash(key), base: base) {
      return slot
    }
    return nil
  }

  package func location(of key: UnsafeRawBufferPointer, base: UnsafeRawPointer?)
    -> RecordLocation?
  {
    self.slot(of: key, base: base).map { self.slots[$0].location }
  }

  package func location(at slot: Int) -> RecordLocation {
    self.slots[slot].location
  }

  /// Moves the record in `slot`, which keeps its key.
  package mutating func setLocation(_ location: RecordLocation, at slot: Int) {
    self.slots[slot].location = location
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
      self.slots[slot].location = location
    case .vacant(let slot):
      self.insert(location, hash: hash, at: slot)
    }
  }

  /// Adds a key whose ``probe(_:hash:base:)`` returned `.vacant(slot)`, with nothing added or
  /// removed since.
  package mutating func insert(_ location: RecordLocation, hash: UInt32, at slot: Int) {
    self.slots[slot] = Slot(hash: hash, location: location)
    self.count += 1
    self.version &+= 1
    // Keep at least a quarter of the slots empty, so that probes stay short and always end.
    if self.count * 4 > self.capacity * 3 {
      self.resize(to: self.capacity * 2)
    }
  }

  @discardableResult
  package mutating func remove(_ key: UnsafeRawBufferPointer, base: UnsafeRawPointer?)
    -> RecordLocation?
  {
    guard let slot = self.slot(of: key, base: base) else { return nil }
    let location = self.slots[slot].location
    self.remove(at: slot)
    return location
  }

  /// Empties `slot`, moving back the keys after it that would no longer be found, so that the
  /// table never needs markers for removed keys.
  package mutating func remove(at slot: Int) {
    let mask = self.capacity - 1
    var hole = slot
    var index = slot
    while true {
      index = (index + 1) & mask
      let next = self.slots[index]
      if next.hash == 0 {
        break
      }
      // The key can fill the hole if the hole is between its home slot and where it is.
      let home = Int(next.hash) & mask
      if (index - home) & mask >= (index - hole) & mask {
        self.slots[hole] = next
        hole = index
      }
    }
    self.slots[hole].hash = 0
    self.count -= 1
    self.version &+= 1
  }

  /// Removes every key whose location satisfies `shouldRemove`.
  ///
  /// - Returns: How many keys were removed.
  @discardableResult
  package mutating func removeAll(where shouldRemove: (RecordLocation) -> Bool) -> Int {
    var removed = 0
    var index = 0
    // Removing a key can move a later one into its slot, so the slot is checked again. A key can
    // also move from the start of the table to the end and be checked twice, which is harmless.
    while index < self.capacity {
      let slot = self.slots[index]
      if slot.hash != 0 && shouldRemove(slot.location) {
        self.remove(at: index)
        removed += 1
      } else {
        index += 1
      }
    }
    return removed
  }

  /// Removes every key and gives back the table's memory.
  package mutating func removeAll() {
    guard self.count > 0 || self.capacity != Self.minimumCapacity else { return }
    self.slots.deallocate()
    self.capacity = Self.minimumCapacity
    self.slots = Self.allocate(self.capacity)
    self.count = 0
    self.version &+= 1
  }

  /// Makes room for `count` keys without growing again.
  package mutating func reserveCapacity(_ count: Int) {
    let capacity = Self.capacity(for: count)
    if capacity > self.capacity {
      self.resize(to: capacity)
    }
  }

  /// Gives back memory the keys no longer need, after many have been removed or were found to be
  /// overwrites of the same key.
  package mutating func shrinkToFit() {
    let capacity = Self.capacity(for: self.count)
    if capacity < self.capacity {
      self.resize(to: capacity)
    }
  }

  /// The smallest capacity that holds `count` keys with a quarter of the slots empty.
  private static func capacity(for count: Int) -> Int {
    var capacity = Self.minimumCapacity
    while count * 4 > capacity * 3 {
      capacity *= 2
    }
    return capacity
  }

  private mutating func resize(to newCapacity: Int) {
    let oldSlots = self.slots
    let oldCapacity = self.capacity
    self.slots = Self.allocate(newCapacity)
    self.capacity = newCapacity
    let mask = newCapacity - 1
    for index in 0..<oldCapacity where oldSlots[index].hash != 0 {
      var target = Int(oldSlots[index].hash) & mask
      while self.slots[target].hash != 0 {
        target = (target + 1) & mask
      }
      self.slots[target] = oldSlots[index]
    }
    oldSlots.deallocate()
    self.version &+= 1
  }

  // MARK: Enumeration

  /// Calls `body` with every occupied slot and its location, in no particular order.
  package func forEachRecord<E: Error>(
    _ body: (Int, RecordLocation) throws(E) -> Void
  ) throws(E) {
    for index in 0..<self.capacity where self.slots[index].hash != 0 {
      try body(index, self.slots[index].location)
    }
  }

  /// The occupied slots, ordered by where their records are.
  package func slotsInRecordOrder() -> LazyMapSequence<[UInt64], Int> {
    // Sorting plain integers that pack each record's offset above its slot is much faster than
    // sorting with a comparison that reads the table, and the slots are read back out of them
    // rather than copied into an array of their own.
    var packed = [UInt64]()
    packed.reserveCapacity(self.count)
    for index in 0..<self.capacity where self.slots[index].hash != 0 {
      packed.append(UInt64(self.slots[index].location.offset) << 32 | UInt64(index))
    }
    packed.sort()
    return packed.lazy.map { Int(truncatingIfNeeded: $0 & 0xffff_ffff) }
  }
}
