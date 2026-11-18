import Testing

@testable import _SwiftMMKVCore

@Suite struct RecordIndexTests {
  @Test func `Finds Every Key It Holds And None It Does Not`() {
    let records = Records(count: 3_000)
    records.data.withUnsafeBytes { data in
      var index = RecordIndex()
      for location in records.locations {
        index.set(
          location,
          for: RecordIndex.key(at: location, in: data.baseAddress!),
          base: data.baseAddress
        )
      }
      #expect(index.count == records.locations.count)
      for (key, location) in zip(records.keys, records.locations) {
        let found = key.withUnsafeBytes { index.location(of: $0, base: data.baseAddress) }
        #expect(found == location)
      }
      let missing = Array("absent".utf8)
        .withUnsafeBytes { index.slot(of: $0, base: data.baseAddress) }
      #expect(missing == nil)
    }
  }

  @Test(arguments: [1, 2, 3])
  func `Removals Keep Every Other Key Findable`(seed: UInt64) {
    let records = Records(count: 2_000)
    var generator = SeededGenerator(seed: seed)
    records.data.withUnsafeBytes { data in
      let base = data.baseAddress
      var index = RecordIndex()
      var expected = [[UInt8]: RecordLocation]()
      for (key, location) in zip(records.keys, records.locations) {
        key.withUnsafeBytes { index.set(location, for: $0, base: base) }
        expected[key] = location
      }
      // Remove keys one at a time, then by a condition, checking every key after each step.
      for key in records.keys.shuffled(using: &generator).prefix(700) {
        let removed = key.withUnsafeBytes { index.remove($0, base: base) }
        #expect(removed == expected.removeValue(forKey: key))
      }
      Self.expectContents(of: index, equal: expected, keys: records.keys, base: base)

      let removedCount = index.removeAll { $0.offset % 3 == 0 }
      let beforeFilter = expected.count
      expected = expected.filter { $0.value.offset % 3 != 0 }
      #expect(removedCount == beforeFilter - expected.count)
      Self.expectContents(of: index, equal: expected, keys: records.keys, base: base)

      // Keys added back go into the slots that removals freed.
      for (key, location) in zip(records.keys, records.locations).shuffled(using: &generator)
        .prefix(500)
      {
        key.withUnsafeBytes { index.set(location, for: $0, base: base) }
        expected[key] = location
      }
      Self.expectContents(of: index, equal: expected, keys: records.keys, base: base)
    }
  }

  @Test func `Moving A Record Keeps Its Slot And Version`() {
    let records = Records(count: 100)
    records.data.withUnsafeBytes { data in
      let base = data.baseAddress
      var index = RecordIndex()
      for (key, location) in zip(records.keys, records.locations) {
        key.withUnsafeBytes { index.set(location, for: $0, base: base) }
      }
      let slot = records.keys[7].withUnsafeBytes { index.slot(of: $0, base: base) }!
      let version = index.version
      var moved = index.location(at: slot)
      moved.valueSize += 1
      index.setLocation(moved, at: slot)
      #expect(index.version == version)
      #expect(records.keys[7].withUnsafeBytes { index.location(of: $0, base: base) } == moved)
    }
  }

  @Test func `Slots In Record Order Follow The Offsets`() {
    let records = Records(count: 500)
    records.data.withUnsafeBytes { data in
      let base = data.baseAddress
      var index = RecordIndex()
      for (key, location) in zip(records.keys, records.locations).reversed() {
        key.withUnsafeBytes { index.set(location, for: $0, base: base) }
      }
      let offsets = Array(index.slotsInRecordOrder()).map { index.location(at: $0).offset }
      #expect(offsets == records.locations.map(\.offset))
    }
  }

  @Test func `Removing Everything Empties The Index`() {
    let records = Records(count: 100)
    records.data.withUnsafeBytes { data in
      let base = data.baseAddress
      var index = RecordIndex()
      for (key, location) in zip(records.keys, records.locations) {
        key.withUnsafeBytes { index.set(location, for: $0, base: base) }
      }
      index.removeAll()
      let count = index.count
      #expect(count == 0)
      #expect(records.keys[0].withUnsafeBytes { index.slot(of: $0, base: base) } == nil)
    }
  }

  private static func expectContents(
    of index: borrowing RecordIndex,
    equal expected: [[UInt8]: RecordLocation],
    keys: [[UInt8]],
    base: UnsafeRawPointer?
  ) {
    #expect(index.count == expected.count)
    for key in keys {
      let found = key.withUnsafeBytes { index.location(of: $0, base: base) }
      #expect(found == expected[key])
    }
  }
}

/// A block of records, one per key, as a data file holds them.
private struct Records {
  var data = [UInt8]()
  var keys = [[UInt8]]()
  var locations = [RecordLocation]()

  init(count: Int) {
    for number in 0..<count {
      // Keys of several lengths, so that hashing covers whole words and leftover bytes.
      let key = Array("key-\(number)-\(String(repeating: "x", count: number % 13))".utf8)
      let value: [UInt8] = [UInt8(truncatingIfNeeded: number), 1, 2]
      let offset = self.data.count
      self.data.append(contentsOf: varint(key.count) + key + varint(value.count) + value)
      self.keys.append(key)
      self.locations.append(
        RecordLocation(keySize: key.count, valueSize: value.count, offset: offset)
      )
    }
  }
}

private func varint(_ value: Int) -> [UInt8] {
  var bytes = [UInt8]()
  var remaining = UInt32(value)
  while remaining > 0x7f {
    bytes.append(UInt8(remaining & 0x7f) | 0x80)
    remaining >>= 7
  }
  bytes.append(UInt8(remaining))
  return bytes
}

/// SplitMix64, so that a failing seed reproduces.
private struct SeededGenerator: RandomNumberGenerator {
  var state: UInt64

  init(seed: UInt64) {
    self.state = seed
  }

  mutating func next() -> UInt64 {
    self.state &+= 0x9E37_79B9_7F4A_7C15
    var value = self.state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
}
