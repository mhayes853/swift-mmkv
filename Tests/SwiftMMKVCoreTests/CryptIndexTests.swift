import Testing

@testable import _SwiftMMKVCore

@Suite struct CryptIndexTests {
  /// What a model of the index holds for a key.
  private enum Expected: Equatable {
    case memory([UInt8], order: UInt32)
    case offset(CryptRecord)

    init(_ entry: CryptEntry) {
      switch entry {
      case .memory(let value, let order): self = .memory(Array(value), order: order)
      case .offset(let record): self = .offset(record)
      }
    }
  }

  @Test(arguments: [1, 2, 3, 4])
  func `Keeps Every Entry Through Replacements, Removals And Compaction`(seed: UInt64) {
    var generator = SeededGenerator(seed: seed)
    var index = CryptIndex()
    var expected = [[UInt8]: Expected]()
    let keys = (0..<400).map { Array("key-\($0)-\(String(repeating: "k", count: $0 % 9))".utf8) }

    for step in 0..<20_000 {
      let key = keys.randomElement(using: &generator)!
      switch Int.random(in: 0..<10, using: &generator) {
      case 0, 1:
        let removed = key.withUnsafeBytes { index.remove($0) }
        #expect(removed == (expected.removeValue(forKey: key) != nil))
      case 2:
        let record = CryptRecord(
          keySize: key.count,
          valueSize: Int.random(in: 257...5_000, using: &generator),
          offset: step,
          state: CipherState(
            vector: (0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) },
            number: UInt32.random(in: 0..<16, using: &generator)
          )
        )
        key.withUnsafeBytes { index.setRecord(record, for: $0) }
        expected[key] = .offset(record)
      case 3:
        // A value already in the index, written back under another key, as reading a value and
        // writing it elsewhere does.
        guard
          let source = expected.first(where: { if case .memory = $0.value { true } else { false } })
        else { continue }
        let order = UInt32(step)
        source.key.withUnsafeBytes { sourceKey in
          guard case .memory(let value, _) = index.entry(of: sourceKey) else {
            Issue.record("missing \(source.key)")
            return
          }
          key.withUnsafeBytes { index.setValue(value, order: order, for: $0) }
        }
        guard case .memory(let value, _) = source.value else { continue }
        expected[key] = .memory(value, order: order)
      default:
        // Sizes that repeat, so that some replacements fit in place.
        let length = [0, 1, 8, 8, 40, 256][Int.random(in: 0..<6, using: &generator)]
        let value = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
        value.withUnsafeBytes { value in
          key.withUnsafeBytes { index.setValue(value, order: UInt32(step), for: $0) }
        }
        expected[key] = .memory(value, order: UInt32(step))
      }
      if step % 997 == 0 {
        Self.expectContents(of: index, equal: expected, keys: keys)
      }
    }
    Self.expectContents(of: index, equal: expected, keys: keys)

    let removed = index.removeAll { $0.realValueSize % 2 == 0 }
    let before = expected.count
    expected = expected.filter { entry in
      switch entry.value {
      case .memory(let value, _): value.count % 2 != 0
      case .offset(let record): record.valueSize % 2 != 0
      }
    }
    #expect(removed == before - expected.count)
    Self.expectContents(of: index, equal: expected, keys: keys)
  }

  @Test func `Moving A Record Keeps Its Key`() {
    var index = CryptIndex()
    let key = Array("large".utf8)
    let record = CryptRecord(
      keySize: key.count,
      valueSize: 1_000,
      offset: 40,
      state: CipherState(vector: Array(repeating: 1, count: 16), number: 3)
    )
    key.withUnsafeBytes { index.setRecord(record, for: $0) }
    let slot = key.withUnsafeBytes { index.slot(of: $0) }!
    var moved = record
    moved.offset = 4
    moved.state = CipherState(vector: Array(repeating: 2, count: 16), number: 0)
    index.setRecord(moved, at: slot)
    #expect(Array(index.key(at: slot)) == key)
    guard case .offset(let found) = key.withUnsafeBytes({ index.entry(of: $0) }) else {
      Issue.record("missing")
      return
    }
    #expect(found.offset == 4)
    #expect(found.state == moved.state)
  }

  @Test func `Record Order Follows Where Records Are`() {
    var index = CryptIndex()
    for (position, name) in [(30, "c"), (10, "a"), (20, "b")] {
      Array(name.utf8)
        .withUnsafeBytes { key in
          Array("v".utf8).withUnsafeBytes { index.setValue($0, order: UInt32(position), for: key) }
        }
    }
    let keys = Array(index.slotsInRecordOrder())
      .map { String(decoding: index.key(at: $0), as: UTF8.self) }
    #expect(keys == ["a", "b", "c"])
  }

  private static func expectContents(
    of index: borrowing CryptIndex,
    equal expected: [[UInt8]: Expected],
    keys: [[UInt8]]
  ) {
    #expect(index.count == expected.count)
    for key in keys {
      let found = key.withUnsafeBytes { index.entry(of: $0) }.map(Expected.init)
      #expect(found == expected[key], "\(String(decoding: key, as: UTF8.self))")
    }
    var listed = Set<[UInt8]>()
    index.forEachEntry { slot, _ in listed.insert(Array(index.key(at: slot))) }
    #expect(listed == Set(expected.keys))
  }
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
