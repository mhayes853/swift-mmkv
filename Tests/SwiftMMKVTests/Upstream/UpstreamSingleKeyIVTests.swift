import Foundation
import SwiftMMKV
import Testing

/// Ports of MMKV v2.4.3's `POSIX/demo/TestSingleKeyIV.cpp`. `MANIFEST.md` maps every upstream
/// function.
///
/// The scenarios overwrite one key and inspect the files after each write. In an encrypted
/// store, AES-CFB keystream depends only on the key and the IV, so a replacement must either
/// leave the old ciphertext where it was and append past it, or write everything again under a
/// fresh IV. Re-encrypting old offsets under the same IV would let anyone holding two snapshots
/// XOR them into the plaintexts.
@Suite(.requires(.store)) struct UpstreamSingleKeyIVTests {
  private static let key128 = "0123456789abcdef"
  private static let key256 = "0123456789abcdef0123456789abcdef"

  @Test(.requires(.encryption)) func `Overwriting An AES-128 Key Never Reuses Keystream`() throws {
    // Upstream: TestSingleKeyIV.cpp overwriteSizes (aes128)
    try self.overwriteSizes(
      id: "aes128",
      configuration: Configuration(encryption: .aes128(key: Self.key128)),
      inspectLeak: true
    )
  }

  @Test(.requires(.encryption)) func `Overwriting An AES-256 Key Never Reuses Keystream`() throws {
    // Upstream: TestSingleKeyIV.cpp overwriteSizes (aes256)
    try self.overwriteSizes(
      id: "aes256",
      configuration: Configuration(encryption: .aes256(key: Self.key256)),
      inspectLeak: true
    )
  }

  @Test(.requires(.encryption, .expiry))
  func `Overwriting An Encrypted Expiring Key Never Reuses Keystream`() throws {
    // Upstream: TestSingleKeyIV.cpp overwriteSizes (expiry)
    // Upstream gives the store a default expiry of an hour, which the package cannot, so each
    // write passes it instead.
    try self.overwriteSizes(
      id: "expiry",
      configuration: Configuration(encryption: .aes128(key: Self.key128), expiry: .seconds(3600)),
      inspectLeak: false
    )
  }

  @Test func `Overwriting A Plain Key Keeps The Files Valid`() throws {
    // Upstream: TestSingleKeyIV.cpp overwriteSizes (plain)
    try self.overwriteSizes(id: "plain", configuration: Configuration(), inspectLeak: false)
  }

  @Test(.requires(.encryption)) func `Overwriting After The File Grows Never Reuses Keystream`()
    throws
  {
    // Upstream: TestSingleKeyIV.cpp capacityGrowth
    let configuration = Configuration(encryption: .aes128(key: Self.key128), expectedCapacity: 0)
    var kv = try Instance(id: "growth", configuration: configuration)
    #expect(kv.store.set(String(repeating: "A", count: 10), forKey: "k"))
    let initialCapacity = try kv.files.dataFileSize()
    let large = String(repeating: "B", count: initialCapacity * 4)

    // The first oversized replacement grows the file; the next one appends to, or compacts,
    // the larger file.
    #expect(kv.store.set(large, forKey: "k"))
    #expect(try kv.files.dataFileSize() > initialCapacity)
    let before = try Snapshot(kv)
    kv = try kv.reloadAndReopen(expecting: large)
    let replacement = String(repeating: "C", count: large.count)
    #expect(kv.store.set(replacement, forKey: "k"))
    let after = try Snapshot(kv)
    #expect(after.isSafeReplacement(of: before))
    kv = try kv.reloadAndReopen(expecting: replacement)
  }

  @Test(.requires(.encryption)) func `Overwriting With Borrowed Bytes Copies Them`() throws {
    // Upstream: TestSingleKeyIV.cpp borrowedInput
    let configuration = Configuration(encryption: .aes128(key: Self.key128))
    var kv = try Instance(id: "borrowed", configuration: configuration)
    #expect(kv.store.set(String(repeating: "A", count: 100), forKey: "k"))
    let before = try Snapshot(kv)
    var source = [UInt8](repeating: UInt8(ascii: "B"), count: 100)

    let didSet = source.withUnsafeBytes { kv.store.set(unsafeBytes: $0, forKey: "k") }
    #expect(didSet)
    let after = try Snapshot(kv)
    #expect(after.isSafeReplacement(of: before))

    // Replacing the caller's bytes must not change the stored value.
    for index in source.indices { source[index] = UInt8(ascii: "X") }
    kv = try kv.reloadAndReopen(expecting: String(repeating: "B", count: 100))
  }

  @Test(.requires(.encryption)) func `Appending And Emptying After An Overwrite`() throws {
    // Upstream: TestSingleKeyIV.cpp dictionaryTransitions
    let configuration = Configuration(encryption: .aes128(key: Self.key128))
    var kv = try Instance(id: "transitions", configuration: configuration)
    #expect(kv.store.set(String(repeating: "A", count: 300), forKey: "k"))
    let initial = try Snapshot(kv)
    #expect(kv.store.set(String(repeating: "B", count: 300), forKey: "k"))
    let overwritten = try Snapshot(kv)
    #expect(overwritten.isSafeReplacement(of: initial))

    // Appending after a replacement continues from the current cipher state, and the first
    // value still decrypts.
    #expect(kv.store.set(String(repeating: "C", count: 300), forKey: "other"))
    func expectTwoKeys(_ store: MMKVStore, sourceLocation: SourceLocation = #_sourceLocation) {
      #expect(
        store.value(forKey: "k", as: String.self) == String(repeating: "B", count: 300),
        sourceLocation: sourceLocation
      )
      #expect(
        store.value(forKey: "other", as: String.self) == String(repeating: "C", count: 300),
        sourceLocation: sourceLocation
      )
      #expect(store.count == 2, sourceLocation: sourceLocation)
    }
    let appended = try Snapshot(kv)
    #expect(appended.iv == overwritten.iv, "An ordinary append changed the IV")
    expectTwoKeys(kv.store)
    let reloaded = try kv.reopen()
    #expect(reloaded.files.isValid())
    expectTwoKeys(reloaded.store)
    kv = reloaded

    // Removing every key leaves a log of removals, and the next insert must not reuse the IV
    // those were written under.
    #expect(kv.store.removeValue(forKey: "other"))
    #expect(kv.store.removeValue(forKey: "k"))
    #expect(kv.store.count == 0)
    #expect(try kv.files.metadata().actualSize > 0)
    let removed = try Snapshot(kv)
    #expect(kv.store.set(String(repeating: "D", count: 300), forKey: "k"))
    let inserted = try Snapshot(kv)
    #expect(inserted.iv != removed.iv, "An insert into an emptied store reused the IV")
    kv = try kv.reloadAndReopen(expecting: String(repeating: "D", count: 300))
  }

  @Test(.requires(.encryption)) func `Compaction Writes A Fresh IV`() throws {
    // Upstream: TestSingleKeyIV.cpp forcedCompaction
    let configuration = Configuration(encryption: .aes128(key: Self.key128), expectedCapacity: 0)
    var kv = try Instance(id: "compaction", configuration: configuration)
    #expect(kv.store.set(String(repeating: "A", count: 300), forKey: "k"))
    let valueSize = try kv.files.dataFileSize() / 10
    var previous = try Snapshot(kv)
    var rotatedIV = false
    var value = ""

    // Roughly ten values fill the file, so repeated replacements must compact it, and every
    // compaction must write a fresh IV.
    for index in 0..<32 {
      let letter = Character(UnicodeScalar(UInt8(ascii: "B") + UInt8(index % 24)))
      value = String(repeating: letter, count: valueSize)
      #expect(kv.store.set(value, forKey: "k"))
      let current = try Snapshot(kv)
      #expect(current.isSafeReplacement(of: previous))
      kv.expectValue(value)
      if current.iv != previous.iv {
        rotatedIV = true
        kv = try kv.reloadAndReopen(expecting: value)
      }
      previous = current
    }

    #expect(rotatedIV, "Repeated replacements never compacted the file with a fresh IV")
    kv = try kv.reloadAndReopen(expecting: value)
  }

  /// Upstream's `overwriteSizes`: replacements that cross the core's small, heap-backed, and
  /// offset-backed value sizes without growing the file.
  private func overwriteSizes(
    id: String,
    configuration: Configuration,
    inspectLeak: Bool
  ) throws {
    var kv = try Instance(id: id, configuration: configuration)
    let initial = String(repeating: "Z", count: 10)
    #expect(kv.store.set(initial, forKey: "k", expiry: configuration.expiry.map(MMKVExpiry.after)))
    var previous = try Snapshot(kv)
    var knownPlaintext: Snapshot?
    let values = [
      String(repeating: "A", count: 10), String(repeating: "B", count: 10),
      String(repeating: "C", count: 100), String(repeating: "D", count: 300),
      String(repeating: "E", count: 32768), String(repeating: "F", count: 3),
      String(repeating: "G", count: 300)
    ]

    for (index, value) in values.enumerated() {
      #expect(kv.store.set(value, forKey: "k", expiry: configuration.expiry.map(MMKVExpiry.after)))
      let current = try Snapshot(kv)
      if configuration.encryption != nil {
        #expect(current.isSafeReplacement(of: previous), "Replacing with \(value.count) bytes")
      }
      if inspectLeak && index == 0 {
        knownPlaintext = current
      } else if inspectLeak && index == 1, let knownPlaintext {
        Self.expectNoKnownPlaintextLeak(first: knownPlaintext, second: current)
      }
      kv = try kv.reloadAndReopen(expecting: value)
      previous = current
    }
  }

  /// Upstream's `securityRegression`: whether two snapshots of the store holding "AAAAAAAAAA" and
  /// then "BBBBBBBBBB" under the key "k" give away the second value to someone who knows the
  /// first.
  private static func expectNoKnownPlaintextLeak(first: Snapshot, second: Snapshot) {
    if first.iv == second.iv {
      // The first entry is still there, which is safe only if the new one starts past it.
      #expect(second.preservesCiphertextAndAppends(first))
      return
    }
    // Bytes 0 to 3 are the plain-text header and 4 to 7 the size holder. With the key "k" and a
    // ten-byte string, 8 to 11 are fixed framing, and 12 to 19 are eight value bytes in the first
    // AES block, whose keystream depends only on the IV and the key.
    #expect(first.ciphertext.count >= 20 && second.ciphertext.count >= 20)
    guard first.ciphertext.count >= 20 && second.ciphertext.count >= 20 else { return }
    let sameFraming = (8..<12).allSatisfy { first.ciphertext[$0] == second.ciphertext[$0] }
    let recoveredValue = (12..<20)
      .allSatisfy {
        UInt8(ascii: "A") ^ first.ciphertext[$0] ^ second.ciphertext[$0] == UInt8(ascii: "B")
      }
    #expect(!sameFraming, "The fixed framing encrypts identically across overwrites")
    #expect(!recoveredValue, "Known plaintext recovers all eight bytes of the replacement")
  }
}

// MARK: - Helpers

extension UpstreamSingleKeyIVTests {
  /// How upstream configures each scenario's store.
  fileprivate struct Configuration {
    var encryption: MMKVConfiguration.Encryption?
    /// Upstream's default is 128 KiB, so replacements do not grow the file.
    var expectedCapacity = 128 * 1024
    /// The expiry upstream's store gives every write by default.
    var expiry: Duration?
  }

  /// An open store and its files, which change identity at every reopen.
  fileprivate struct Instance {
    let store: MMKVStore
    let files: StoreFiles
    let configuration: Configuration
    private let name: String
    private let reopenings: Int

    init(
      id: String,
      configuration: Configuration,
      rootDirectory: String = temporaryRootDirectory(),
      reopenings: Int = 0
    ) throws {
      let fileID = MMKVStore.ID(rawValue: reopenings == 0 ? id : "\(id)-\(reopenings)")
      self.store = try makeStore(
        id: fileID,
        rootDirectory: rootDirectory,
        encryption: configuration.encryption,
        expectedCapacity: configuration.expectedCapacity
      )
      self.files = StoreFiles(id: fileID, rootDirectory: rootDirectory)
      self.configuration = configuration
      self.name = id
      self.reopenings = reopenings
    }

    /// Upstream's `verifyString`.
    func expectValue(_ expected: String, sourceLocation: SourceLocation = #_sourceLocation) {
      #expect(
        self.store.value(forKey: "k", as: String.self) == expected,
        "The value differs after an overwrite",
        sourceLocation: sourceLocation
      )
      #expect(self.store.count == 1, sourceLocation: sourceLocation)
    }

    /// A fresh instance over a copy of the files, standing in for closing and opening again.
    func reopen() throws -> Instance {
      try copyFiles(
        of: self.store,
        in: self.files.rootDirectory,
        to: "\(self.name)-\(self.reopenings + 1)"
      )
      return try Instance(
        id: self.name,
        configuration: self.configuration,
        rootDirectory: self.files.rootDirectory,
        reopenings: self.reopenings + 1
      )
    }

    /// Upstream's `reloadAndReopen`: checks the value, that the files pass MMKV's integrity
    /// check, and that a fresh instance reads the value too, then carries on with that instance.
    func reloadAndReopen(
      expecting expected: String,
      sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> Instance {
      self.expectValue(expected, sourceLocation: sourceLocation)
      #expect(
        self.files.isValid(),
        "The overwrite fails CRC validation",
        sourceLocation: sourceLocation
      )
      let reopened = try self.reopen()
      reopened.expectValue(expected, sourceLocation: sourceLocation)
      return reopened
    }
  }

  /// Upstream's `Snapshot`: the IV and the data file's bytes up to the end of its data.
  fileprivate struct Snapshot {
    let iv: [UInt8]
    let ciphertext: [UInt8]

    init(_ instance: Instance) throws {
      instance.store.sync()
      let metadata = try instance.files.metadata()
      let data = try instance.files.data()
      let end = 4 + Int(metadata.actualSize)
      try #require(data.count >= end, "Truncated data snapshot")
      self.iv = metadata.iv
      self.ciphertext = Array(data[..<end])
    }

    /// Whether every previously written byte is still in place, after the header, and more
    /// bytes follow.
    func preservesCiphertextAndAppends(_ before: Snapshot) -> Bool {
      self.ciphertext.count > before.ciphertext.count
        && before.ciphertext[4...].elementsEqual(self.ciphertext[4..<before.ciphertext.count])
    }

    /// Upstream's `checkEncryptedReplacement`: either a fresh IV, or the old ciphertext
    /// untouched with the replacement appended.
    func isSafeReplacement(of before: Snapshot) -> Bool {
      self.iv != before.iv || self.preservesCiphertextAndAppends(before)
    }
  }
}
