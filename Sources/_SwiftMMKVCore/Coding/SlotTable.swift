// The hash table under both kinds of store's index: open addressing with linear probing, over
// slots that each hold a key's hash and whatever the index records about the key. The table keeps
// no keys. An index tells it how to compare a key with a slot's, wherever the index keeps them.

/// A slot of a ``SlotTable``.
protocol HashTableSlot {
  /// An empty slot.
  static var empty: Self { get }
  /// The key's hash, which is never 0, or 0 for an empty slot.
  var hash: UInt32 { get set }
}

/// The result of looking up a key.
package enum HashProbe {
  /// The key is in this slot.
  case found(Int)
  /// The key is absent, and would go in this slot.
  case vacant(Int)
}

/// An open-addressing hash table of slots, with linear probing and no markers for removed keys.
struct SlotTable<Slot: HashTableSlot>: ~Copyable {
  private(set) var slots: UnsafeMutablePointer<Slot>
  /// A power of two, so that a hash's low bits pick a slot.
  private(set) var capacity: Int
  private(set) var count = 0
  /// Changes whenever a key is added or removed, or the table is resized, so that a caller holding
  /// a slot number can tell whether it still refers to the same key.
  private(set) var version = 0
  private let seed: UInt64

  static var minimumCapacity: Int { 16 }

  init() {
    self.capacity = Self.minimumCapacity
    self.slots = Self.allocate(self.capacity)
    self.seed = UInt64.random(in: .min ... .max)
  }

  deinit {
    self.slots.deallocate()
  }

  private static func allocate(_ capacity: Int) -> UnsafeMutablePointer<Slot> {
    let slots = UnsafeMutablePointer<Slot>.allocate(capacity: capacity)
    slots.initialize(repeating: .empty, count: capacity)
    return slots
  }

  /// The memory the slots take.
  var byteCount: Int {
    self.capacity * MemoryLayout<Slot>.stride
  }

  // MARK: Hashing

  /// The hash of `key` in this table: a multiply-and-fold hash over eight bytes at a time, seeded
  /// for each table.
  func hash(_ key: UnsafeRawBufferPointer) -> UInt32 {
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

  // MARK: Lookup

  /// Finds the key whose hash is `hash`, comparing it with each candidate slot's key with
  /// `matches`.
  @inline(__always)
  func probe(hash: UInt32, matches: (Slot) -> Bool) -> HashProbe {
    let mask = self.capacity - 1
    var index = Int(hash) & mask
    while true {
      let slot = self.slots[index]
      if slot.hash == 0 {
        return .vacant(index)
      }
      if slot.hash == hash && matches(slot) {
        return .found(index)
      }
      index = (index + 1) & mask
    }
  }

  /// The slot at `index`. Setting it must keep its hash.
  subscript(index: Int) -> Slot {
    get { self.slots[index] }
    set { self.slots[index] = newValue }
  }

  // MARK: Adding and removing

  /// Adds `slot` where ``probe(hash:matches:)`` returned `.vacant(index)`, with nothing added or
  /// removed since.
  mutating func insert(_ slot: Slot, at index: Int) {
    self.slots[index] = slot
    self.count += 1
    self.version &+= 1
    // Keep at least a quarter of the slots empty, so that probes stay short and always end.
    if self.count * 4 > self.capacity * 3 {
      self.resize(to: self.capacity * 2)
    }
  }

  /// Empties the slot at `index`, moving back the slots after it that would no longer be found.
  mutating func remove(at index: Int) {
    let mask = self.capacity - 1
    var hole = index
    var next = index
    while true {
      next = (next + 1) & mask
      let slot = self.slots[next]
      if slot.hash == 0 {
        break
      }
      // The slot can fill the hole if the hole is between its home slot and where it is.
      let home = Int(slot.hash) & mask
      if (next - home) & mask >= (next - hole) & mask {
        self.slots[hole] = slot
        hole = next
      }
    }
    self.slots[hole] = .empty
    self.count -= 1
    self.version &+= 1
  }

  /// Removes every slot that satisfies `shouldRemove`.
  ///
  /// - Returns: How many slots were removed.
  @discardableResult
  mutating func removeAll(where shouldRemove: (Slot) -> Bool) -> Int {
    var removed = 0
    var index = 0
    // Removing a slot can move a later one into its place, so the place is checked again. A slot
    // can also move from the start of the table to the end and be checked twice, so
    // `shouldRemove` must give the same answer for a slot every time it is asked.
    while index < self.capacity {
      let slot = self.slots[index]
      if slot.hash != 0 && shouldRemove(slot) {
        self.remove(at: index)
        removed += 1
      } else {
        index += 1
      }
    }
    return removed
  }

  /// Removes every slot and gives back the table's memory.
  mutating func removeAll() {
    guard self.count > 0 || self.capacity != Self.minimumCapacity else { return }
    self.slots.deallocate()
    self.capacity = Self.minimumCapacity
    self.slots = Self.allocate(self.capacity)
    self.count = 0
    self.version &+= 1
  }

  /// Makes room for `count` slots without growing again.
  mutating func reserveCapacity(_ count: Int) {
    let capacity = Self.capacity(for: count)
    if capacity > self.capacity {
      self.resize(to: capacity)
    }
  }

  /// Gives back memory the slots no longer need.
  mutating func shrinkToFit() {
    let capacity = Self.capacity(for: self.count)
    if capacity < self.capacity {
      self.resize(to: capacity)
    }
  }

  /// The smallest capacity that holds `count` slots with a quarter of them empty.
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

  /// Calls `body` with every occupied slot and its index, in no particular order.
  func forEachSlot<E: Error>(_ body: (Int, Slot) throws(E) -> Void) throws(E) {
    for index in 0..<self.capacity where self.slots[index].hash != 0 {
      try body(index, self.slots[index])
    }
  }

  /// The indices of the occupied slots, ordered by `order`, and by index where two slots are
  /// equal in it.
  func slotIndices(orderedBy order: (Slot) -> UInt32) -> LazyMapSequence<[UInt64], Int> {
    // Sorting plain integers that pack each slot's place in the order above its index is much
    // faster than sorting with a comparison that reads the table, and the indices are read back
    // out of them rather than copied into an array of their own.
    let slots = self.slots
    let capacity = self.capacity
    var packed = [UInt64](unsafeUninitializedCapacity: self.count) { buffer, initialized in
      var packedCount = 0
      for index in 0..<capacity where slots[index].hash != 0 {
        buffer[packedCount] = UInt64(order(slots[index])) << 32 | UInt64(index)
        packedCount += 1
      }
      initialized = packedCount
    }
    // The indices go in ascending, so a stable sort by the order alone sorts them by both.
    packed.withUnsafeMutableBufferPointer { sortByHighWord($0) }
    return packed.lazy.map { Int(truncatingIfNeeded: $0 & 0xffff_ffff) }
  }
}

/// Sorts `values`, whose low 32 bits are in ascending order, into ascending order.
///
/// Only the high 32 bits need sorting, as long as values whose high bits are equal stay in the
/// order they were in. This is a least-significant-digit radix sort that does so a digit at a
/// time: each pass counts how many values have each digit, then moves the values into a bucket
/// for each digit, keeping their order within a bucket, so after the pass for the top digit they
/// are in order. It does a fixed amount of work for each value, where a comparison sort's grows
/// with the count.
///
/// Only the bits that differ between values are sorted, which one read of the values finds. The
/// top bits of a file's offsets are the same in every value, so a file under 4 MB has at most 22
/// bits to sort, and two passes of 11-bit digits do it, where byte digits would take three.
func sortByHighWord(_ values: UnsafeMutableBufferPointer<UInt64>) {
  let count = values.count
  // Below this, the setup costs more than comparing does.
  guard count > 128 else {
    var values = values
    values.sort()
    return
  }
  // The compiler vectorizes this loop.
  var anySet: UInt64 = 0
  var allSet: UInt64 = ~0
  for value in values {
    anySet |= value
    allSet &= value
  }
  let differing = UInt32(truncatingIfNeeded: (anySet ^ allSet) >> 32)
  guard differing != 0 else { return }
  let lowestBit = differing.trailingZeroBitCount
  let bits = UInt32.bitWidth - differing.leadingZeroBitCount - lowestBit
  // Digits of up to 11 bits keep the counts in 16 KB, which stays in the L1 cache.
  let passes = (bits + 10) / 11
  let width = (bits + passes - 1) / passes
  let bucketCount = 1 << width
  let mask = UInt64(bucketCount - 1)
  withUnsafeTemporaryAllocation(of: Int.self, capacity: bucketCount) { counts in
    withUnsafeTemporaryAllocation(of: UInt64.self, capacity: count) { scratch in
      var source = values
      var destination = scratch
      for pass in 0..<passes {
        let shift = UInt64(32 + lowestBit + pass * width)
        counts.initialize(repeating: 0)
        for value in source {
          counts[Int(truncatingIfNeeded: (value >> shift) & mask)] += 1
        }
        // Each bucket's count becomes where its first value goes.
        var start = 0
        for bucket in 0..<bucketCount {
          let bucketValues = counts[bucket]
          counts[bucket] = start
          start += bucketValues
        }
        for value in source {
          let bucket = Int(truncatingIfNeeded: (value >> shift) & mask)
          destination[counts[bucket]] = value
          counts[bucket] += 1
        }
        swap(&source, &destination)
      }
      if source.baseAddress != values.baseAddress {
        _ = values.update(fromContentsOf: source)
      }
    }
  }
}
