import Foundation
import SwiftMMKV
import Testing

/// Ports of MMKV v2.4.3's `POSIX/demo/UnitTest.cpp`. `MANIFEST.md` maps every upstream test.
///
/// Upstream reads a missing key as the default value it passes in; the package reads it as
/// `nil`, so the ports check for `nil` where upstream checks for its default.
@Suite(.requires(.store)) struct UpstreamUnitTests {
  // MARK: - Values

  @Test func `Bool Round Trips`() throws {
    // Upstream: UnitTest.cpp testBool
    let store = try makeStore()

    #expect(store.set(true, forKey: "bool"))

    #expect(store.value(forKey: "bool", as: Bool.self) == true)
    #expect(store.value(forKey: keyNotExist, as: Bool.self) == nil)
  }

  @Test func `Int32 Round Trips`() throws {
    // Upstream: UnitTest.cpp testInt32
    let store = try makeStore()

    #expect(store.set(Int32.max, forKey: "int32"))

    #expect(store.value(forKey: "int32", as: Int32.self) == .max)
    #expect(store.value(forKey: keyNotExist, as: Int32.self) == nil)
  }

  @Test func `UInt32 Round Trips`() throws {
    // Upstream: UnitTest.cpp testUInt32
    let store = try makeStore()

    #expect(store.set(UInt32.max, forKey: "uint32"))

    #expect(store.value(forKey: "uint32", as: UInt32.self) == .max)
    #expect(store.value(forKey: keyNotExist, as: UInt32.self) == nil)
  }

  @Test func `Int64 Round Trips`() throws {
    // Upstream: UnitTest.cpp testInt64
    let store = try makeStore()

    #expect(store.set(Int64.min, forKey: "int64"))

    #expect(store.value(forKey: "int64", as: Int64.self) == .min)
    #expect(store.value(forKey: keyNotExist, as: Int64.self) == nil)
  }

  @Test func `UInt64 Round Trips`() throws {
    // Upstream: UnitTest.cpp testUInt64
    let store = try makeStore()

    #expect(store.set(UInt64.max, forKey: "uint64"))

    #expect(store.value(forKey: "uint64", as: UInt64.self) == .max)
    #expect(store.value(forKey: keyNotExist, as: UInt64.self) == nil)
  }

  @Test func `Float Round Trips`() throws {
    // Upstream: UnitTest.cpp testFloat
    let store = try makeStore()

    #expect(store.set(Float.greatestFiniteMagnitude, forKey: "float"))

    #expect(store.value(forKey: "float", as: Float.self) == .greatestFiniteMagnitude)
    #expect(store.value(forKey: keyNotExist, as: Float.self) == nil)
  }

  @Test func `Double Round Trips`() throws {
    // Upstream: UnitTest.cpp testDouble
    let store = try makeStore()

    #expect(store.set(Double.greatestFiniteMagnitude, forKey: "double"))

    #expect(store.value(forKey: "double", as: Double.self) == .greatestFiniteMagnitude)
    #expect(store.value(forKey: keyNotExist, as: Double.self) == nil)
  }

  @Test func `String Round Trips`() throws {
    // Upstream: UnitTest.cpp testString
    let store = try makeStore()
    let string = "Hello 2018 world cup 世界杯"
    let cString = "Hello 2022 world cup 世界杯"

    #expect(store.set(string, forKey: "string"))
    #expect(store.set(cString, forKey: "cstring"))

    #expect(store.value(forKey: "string", as: String.self) == string)
    #expect(store.value(forKey: "cstring", as: String.self) == cString)
    #expect(store.value(forKey: keyNotExist, as: String.self) == nil)
  }

  @Test func `Bytes Round Trip`() throws {
    // Upstream: UnitTest.cpp testBytes
    let store = try makeStore()
    let bytes = Array("Hello 2018 world cup 世界杯".utf8)

    #expect(store.set(bytes, forKey: "bytes"))

    #expect(store.value(forKey: "bytes", as: [UInt8].self) == bytes)
    // Upstream reads an empty buffer for a missing key.
    #expect(store.value(forKey: keyNotExist, as: [UInt8].self) == nil)
  }

  @Test func `String Vector Round Trips`() throws {
    // Upstream: UnitTest.cpp testVector
    let store = try makeStore()
    let vector = ["1", "0", "2", "4"]

    #expect(store.set(vector, forKey: "vector"))

    #expect(store.value(forKey: "vector", as: [String].self) == vector)
  }

  @Test func `Removes One Key And Several Keys`() throws {
    // Upstream: UnitTest.cpp testRemove
    let store = try makeStore()
    let vector = ["key", "value"]
    let didSet = [
      store.set(true, forKey: "bool_1"),
      store.set(Int32.max, forKey: "int_1"),
      store.set(Int64.max, forKey: "long_1"),
      store.set(Float.leastNormalMagnitude, forKey: "float_1"),
      store.set(Double.leastNormalMagnitude, forKey: "double_1"),
      store.set("hello", forKey: "string_1"),
      store.set(vector, forKey: "vector_1")
    ]
    #expect(didSet.allSatisfy { $0 })

    let count = store.count
    store.removeValue(forKey: "bool_1")
    store.removeValues(forKeys: ["int_1", "long_1"])

    #expect(store.count == count - 3)
    #expect(store.value(forKey: "bool_1", as: Bool.self) == nil)
    #expect(store.value(forKey: "int_1", as: Int32.self) == nil)
    #expect(store.value(forKey: "long_1", as: Int64.self) == nil)
    #expect(store.value(forKey: "float_1", as: Float.self) == .leastNormalMagnitude)
    #expect(store.value(forKey: "double_1", as: Double.self) == .leastNormalMagnitude)
    #expect(store.value(forKey: "string_1", as: String.self) == "hello")
    #expect(store.value(forKey: "vector_1", as: [String].self) == vector)
  }

  // MARK: - Size limits

  @Test func `Keys Longer Than 65531 Bytes Are Rejected`() throws {
    // Upstream: UnitTest.cpp testOversizedKey
    let store = try makeStore()

    let longest = String(repeating: "A", count: 65531)
    #expect(store.set("V", forKey: longest))
    #expect(store.value(forKey: longest, as: String.self) == "V")

    // The key still fits, but a value long enough to need a two-byte length prefix overflows
    // the pair's 16-bit size, so the update is refused before anything is written.
    #expect(!store.set(String(repeating: "V", count: 127), forKey: longest))
    #expect(store.value(forKey: longest, as: String.self) == "V")
    store.removeValue(forKey: longest)
    #expect(!store.set(String(repeating: "V", count: 127), forKey: longest))
    #expect(!store.contains(longest))

    let tooLong = String(repeating: "B", count: 65532)
    #expect(!store.set("V", forKey: tooLong))
    #expect(store.value(forKey: tooLong, as: String.self) == nil)

    #expect(!store.set("V", forKey: String(repeating: "C", count: 70000)))
  }

  @Test(.requires(.expiry)) func `Expiration Is Not Enabled When A Pair Would Overflow`() throws {
    // Upstream: UnitTest.cpp testOversizedKey
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(id: "oversized", rootDirectory: rootDirectory)
    let key = String(repeating: "D", count: 65531)
    let value = String(repeating: "V", count: 124)
    #expect(store.set(value, forKey: key))

    // Upstream calls `enableAutoKeyExpire()`, which the package does on the first expiring
    // write. Four bytes of expiry would push the value's length prefix to two bytes and overflow
    // the pair's 16-bit size, so expiration stays off and the write fails.
    #expect(!store.set("x", forKey: "other", expiry: .after(.seconds(60))))

    #expect(store.value(forKey: key, as: String.self) == value)
    #expect(!store.contains("other"))
    store.sync()
    #expect(try !StoreFiles(id: "oversized", rootDirectory: rootDirectory).metadata().hasExpiration)
  }

  @Test(.enabled(if: Int.bitWidth == 64)) func `Values Too Large For The File Are Rejected`()
    throws
  {
    // Upstream: UnitTest.cpp testOversizedValue
    let store = try makeStore()
    var sentinel: UInt8 = 0

    withUnsafeBytes(of: &sentinel) { sentinel in
      // Only the first byte exists: the store must refuse these lengths before reading them.
      func oversized(_ count: Int) -> UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: sentinel.baseAddress, count: count)
      }

      store.removeAll()
      #expect(store.set("before", forKey: "value"))
      #expect(!store.set(unsafeBytes: oversized(Int(UInt32.max) - 5), forKey: "value"))
      #expect(store.value(forKey: "value", as: String.self) == "before")
      #expect(store.set("after", forKey: "value"))
      #expect(store.value(forKey: "value", as: String.self) == "after")

      store.removeAll()
      #expect(!store.set(unsafeBytes: oversized(Int(UInt32.max) + 1), forKey: "oversized-append"))
      #expect(store.set("after", forKey: "value"))
      #expect(store.value(forKey: "value", as: String.self) == "after")

      store.removeAll()
      #expect(store.set("before", forKey: "value"))
      #expect(!store.set(unsafeBytes: oversized(Int(UInt32.max) + 1), forKey: "value"))
      #expect(store.value(forKey: "value", as: String.self) == "before")
      #expect(store.set("after", forKey: "value"))
      #expect(store.value(forKey: "value", as: String.self) == "after")
    }
  }

  @Test(.requires(.expiry), .enabled(if: Int.bitWidth == 64))
  func `Expiring Values Too Large For The File Are Rejected`() throws {
    // Upstream: UnitTest.cpp testOversizedValue
    let store = try makeStore()
    var sentinel: UInt8 = 0

    let didSetOversized = withUnsafeBytes(of: &sentinel) { sentinel in
      store.set(
        unsafeBytes: UnsafeRawBufferPointer(
          start: sentinel.baseAddress,
          count: Int(UInt32.max) + 1
        ),
        forKey: "value",
        expiry: .after(.seconds(60))
      )
    }

    #expect(!didSetOversized)
    #expect(store.set("after", forKey: "value", expiry: .after(.seconds(60))))
    #expect(store.value(forKey: "value", as: String.self) == "after")
  }

  // MARK: - Integrity and recovery

  @Test func `The Files Are Valid Until The Metadata Is Truncated`() throws {
    // Upstream: UnitTest.cpp testFileValidation
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(id: "file_validation_test", rootDirectory: rootDirectory)
    #expect(store.set("value", forKey: "key"))
    let files = try copyFiles(of: store, in: rootDirectory, to: "copy")

    // Current-format files keep the size of their data in the metadata, not in the data file's
    // first four bytes.
    #expect(files.isValid())
    #expect(try files.dataHeader() == 0)
    #expect(try files.metadata().version >= StoreMetadata.versionWithActualSize)

    try truncateFile(atPath: files.metadataPath, toSize: 4)
    #expect(!files.isValid())

    // Not upstream: what opening such files does. The metadata file grows back to a page of
    // zeros after the surviving digest, so its version reads as 0 and the size is taken from the
    // data file's header, which is 0. The CRC of no data does not match the digest, and the store
    // opens empty even when asked to recover, then rewrites valid files.
    for recovery in [MMKVConfiguration.Recovery.discard, .recover] {
      let copy = try copyFiles(of: store, in: rootDirectory, to: "truncated-\(recovery)")
      try truncateFile(atPath: copy.metadataPath, toSize: 4)
      let reopened = try makeStore(id: copy.id, rootDirectory: rootDirectory, recovery: recovery)
      #expect(reopened.keys.isEmpty)
      #expect(copy.isValid())
    }
  }

  @Test(.requires(.readOnly), arguments: 1...4)
  func `A Data File Shorter Than Its Header Opens Empty`(fileSize: Int) throws {
    // Upstream: UnitTest.cpp testTinyFileRecovery
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(id: "tiny_file", rootDirectory: rootDirectory)
    #expect(store.set("value", forKey: "key"))
    let files = try copyFiles(of: store, in: rootDirectory, to: "tiny_file_\(fileSize)")

    try truncateFile(atPath: files.dataPath, toSize: fileSize)
    #expect(!files.isValid())

    // Upstream's handler asks to recover; with too little file there is nothing to recover.
    let readOnly = try makeStore(
      id: files.id,
      rootDirectory: rootDirectory,
      isReadOnly: true,
      recovery: .recover
    )
    #expect(readOnly.count == 0)
    #expect(readOnly.value(forKey: "key", as: String.self) == nil)
    // A read-only store never grows its file.
    #expect(try files.dataFileSize() == fileSize)
  }

  @Test(.requires(.readOnly), arguments: [false, true])
  func `A Read Only Store Recovers From The Last Confirmed Size Without Writing`(
    useLastConfirmed: Bool
  ) throws {
    // Upstream: UnitTest.cpp testReadOnlyRecovery
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(id: "source", rootDirectory: rootDirectory)
    #expect(store.set("intact", forKey: "key"))
    let files = try copyFiles(of: store, in: rootDirectory, to: "readonly")
    let goodSize = try files.metadata().actualSize
    let badSize = UInt32(try files.dataFileSize() + 4)

    // The metadata claims more data than the file holds, but its last confirmed size and
    // digest are good. The data file's header holds the good size when that is the way back,
    // and the bad size when only the last confirmed size can be trusted.
    let path = files.metadataPath
    let digest = try files.metadata().crcDigest
    try overwrite(goodSize, atOffset: StoreMetadata.lastConfirmedActualSizeOffset, ofFileAt: path)
    try overwrite(digest, atOffset: StoreMetadata.lastConfirmedCRCDigestOffset, ofFileAt: path)
    try overwrite(badSize, atOffset: StoreMetadata.actualSizeOffset, ofFileAt: path)
    try overwrite(useLastConfirmed ? badSize : goodSize, atOffset: 0, ofFileAt: files.dataPath)
    let metadataBefore = try readFile(atPath: path)
    let dataBefore = try files.data()

    let readOnly = try makeStore(id: files.id, rootDirectory: rootDirectory, isReadOnly: true)

    #expect(readOnly.value(forKey: "key", as: String.self) == "intact")
    #expect(readOnly.keys == ["key"])
    // Recovering does not repair the files of a read-only store.
    #expect(try readFile(atPath: path) == metadataBefore)
    #expect(try files.data() == dataBefore)
  }

  // MARK: - Expiration

  @Test(.requires(.expiry)) func `The Longest Expiration Saturates`() throws {
    // Upstream: UnitTest.cpp testExpirationOverflow
    let store = try makeStore()
    let bytes = Array("bytes".utf8)

    // Upstream also gives the store a default expiration of `UInt32.max` seconds, which the
    // package has no way to set, and writes this key with it.
    #expect(store.set(true, forKey: "expiration_overflow_auto"))
    #expect(
      store.set(
        "manual",
        forKey: "expiration_overflow_manual",
        expiry: .after(.seconds(UInt32.max))
      )
    )
    let didSetBytes = bytes.withUnsafeBytes {
      store.set(
        unsafeBytes: $0,
        forKey: "expiration_overflow_bytes",
        expiry: .after(.seconds(UInt32.max))
      )
    }
    #expect(didSetBytes)

    #expect(store.value(forKey: "expiration_overflow_auto", as: Bool.self) == true)
    #expect(store.value(forKey: "expiration_overflow_manual", as: String.self) == "manual")
    #expect(store.value(forKey: "expiration_overflow_bytes", as: [UInt8].self) == bytes)
    #expect(store.count == 3)
  }

  @Test(.requires(.expiry)) func `Expiring Values Of Every Short Length Round Trip`() throws {
    // Upstream: UnitTest.cpp testExpirationAlignment
    let store = try makeStore()
    try expectExpiringValuesOfEveryShortLengthRoundTrip(in: store)
  }

  @Test(.requires(.expiry, .encryption))
  func `Encrypted Expiring Values Of Every Short Length Round Trip`() throws {
    // Upstream: UnitTest.cpp testExpirationAlignment
    let store = try makeStore(encryption: .aes128(key: "alignment-key"))
    try expectExpiringValuesOfEveryShortLengthRoundTrip(in: store)
  }

  private func expectExpiringValuesOfEveryShortLengthRoundTrip(in store: MMKVStore) throws {
    for length in 1...4 {
      let value = String(repeating: "x", count: length)
      #expect(store.set(value, forKey: "alignment-\(length)", expiry: .after(.seconds(60))))
      #expect(store.value(forKey: "alignment-\(length)", as: String.self) == value)
    }
    #expect(store.count == 4)
  }

  @Test(.requires(.expiry))
  func `The First Read After Reopening Respects Expiration`() async throws {
    // Upstream: UnitTest.cpp testFirstReadAfterReopenRespectsExpiration
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(id: "first-read-expiration", rootDirectory: rootDirectory)
    #expect(store.set(UInt32(123), forKey: "expired", expiry: .after(.seconds(1))))
    try copyFiles(of: store, in: rootDirectory, to: "reopened")
    try await Task.sleep(for: oneSecondExpiry)

    let reopened = try makeStore(id: "reopened", rootDirectory: rootDirectory)

    // Nothing warms the instance up first: this read is the first operation.
    #expect(reopened.value(forKey: "expired", as: UInt32.self) == nil)
  }

  @Test(.requires(.expiry, .readOnly))
  func `A Read Only Store Filters Expired Keys`() async throws {
    // Upstream: UnitTest.cpp testReadOnlyExpiration
    try await expectReadOnlyStoreFiltersExpiredKeys(encryption: nil)
  }

  @Test(.requires(.expiry, .readOnly, .encryption))
  func `A Read Only Encrypted Store Filters Expired Keys`() async throws {
    // Upstream: UnitTest.cpp testReadOnlyExpiration
    try await expectReadOnlyStoreFiltersExpiredKeys(encryption: .aes128(key: "expiration-key"))
  }

  private func expectReadOnlyStoreFiltersExpiredKeys(
    encryption: MMKVConfiguration.Encryption?
  ) async throws {
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(id: "source", rootDirectory: rootDirectory, encryption: encryption)
    #expect(store.set(UInt32(123), forKey: "expired", expiry: .after(.seconds(1))))
    #expect(store.set("live", forKey: "live"))
    store.sync()
    try await Task.sleep(for: oneSecondExpiry)

    // Each check is the first operation on a read-only instance of its own.
    func openReadOnly(_ id: MMKVStore.ID) throws -> MMKVStore {
      try copyFiles(of: store, in: rootDirectory, to: id)
      return try makeStore(
        id: id,
        rootDirectory: rootDirectory,
        isReadOnly: true,
        encryption: encryption
      )
    }
    #expect(try openReadOnly("read").value(forKey: "expired", as: UInt32.self) == nil)
    let forKeys = try openReadOnly("keys")
    let forCount = try openReadOnly("count")
    #expect(forKeys.keys == ["live"])
    #expect(forCount.count == 1)
    // Upstream also checks that an unfiltered count is still 2, which the package cannot ask.
    #expect(try openReadOnly("live").value(forKey: "live", as: String.self) == "live")
  }

  @Test(.requires(.expiry)) func `The First Write After Reopening Keeps Its Value`() throws {
    // Upstream: UnitTest.cpp testFirstWriteAfterReopenPreservesValue
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(id: "first-write-expiration", rootDirectory: rootDirectory)
    try enableExpiration(on: store)
    #expect(store.set("persisted", forKey: "existing"))
    try copyFiles(of: store, in: rootDirectory, to: "reopened")

    let reopened = try makeStore(id: "reopened", rootDirectory: rootDirectory)

    // This write is the first operation, before the metadata is loaded. Even a value that never
    // expires needs four bytes of expiry once the store has expiration enabled, or its last four
    // bytes are taken for a date.
    #expect(reopened.set("ABCD", forKey: "new"))
    #expect(reopened.value(forKey: "new", as: String.self) == "ABCD")
    #expect(reopened.value(forKey: "existing", as: String.self) == "persisted")
  }

  @Test(.requires(.expiry)) func `The First Write After Reopening Works For Every Type`() throws {
    // Upstream: UnitTest.cpp testFirstWriteAfterReopenOverloads
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(id: "first-write-expiration-overloads", rootDirectory: rootDirectory)
    try enableExpiration(on: store)
    var reopenings = 0

    // Each write is the first operation on a fresh instance over the same contents.
    func reopen() throws -> MMKVStore {
      reopenings += 1
      try copyFiles(of: store, in: rootDirectory, to: "reopened-\(reopenings)")
      return try makeStore(id: "reopened-\(reopenings)", rootDirectory: rootDirectory)
    }
    let minute = MMKVExpiry.after(.seconds(60))
    var kv = try reopen()
    #expect(kv.set(true, forKey: "bool", expiry: minute))
    #expect(kv.value(forKey: "bool", as: Bool.self) == true)
    kv = try reopen()
    #expect(kv.set(Int32(-123), forKey: "i32", expiry: minute))
    #expect(kv.value(forKey: "i32", as: Int32.self) == -123)
    kv = try reopen()
    #expect(kv.set(UInt32(123), forKey: "u32", expiry: minute))
    #expect(kv.value(forKey: "u32", as: UInt32.self) == 123)
    kv = try reopen()
    #expect(kv.set(Int64(-123), forKey: "i64", expiry: minute))
    #expect(kv.value(forKey: "i64", as: Int64.self) == -123)
    kv = try reopen()
    #expect(kv.set(UInt64(123), forKey: "u64", expiry: minute))
    #expect(kv.value(forKey: "u64", as: UInt64.self) == 123)
    kv = try reopen()
    #expect(kv.set(Float(1.5), forKey: "float", expiry: minute))
    #expect(kv.value(forKey: "float", as: Float.self) == 1.5)
    kv = try reopen()
    #expect(kv.set(1.5, forKey: "double", expiry: minute))
    #expect(kv.value(forKey: "double", as: Double.self) == 1.5)
    kv = try reopen()
    #expect(kv.set("ABCD", forKey: "string", expiry: minute))
    #expect(kv.value(forKey: "string", as: String.self) == "ABCD")
    kv = try reopen()
    let bytes = Array("ABCD".utf8)
    #expect(bytes.withUnsafeBytes { kv.set(unsafeBytes: $0, forKey: "bytes", expiry: minute) })
    #expect(kv.value(forKey: "bytes", as: [UInt8].self) == bytes)
    kv = try reopen()
    #expect(kv.set(["ABCD", "EFGH"], forKey: "strings", expiry: minute))
    #expect(kv.value(forKey: "strings", as: [String].self) == ["ABCD", "EFGH"])
  }

  // MARK: - Encryption

  @Test(.requires(.encryption)) func `Rekeying With The Same Key Switches To AES-256`() throws {
    // Upstream: UnitTest.cpp testCryptoRandomAndWipe
    let rootDirectory = temporaryRootDirectory()
    let key = "0123456789abcdef"
    let store = try makeStore(
      id: "aes-mode-switch",
      rootDirectory: rootDirectory,
      encryption: .aes128(key: key)
    )
    #expect(store.set("payload", forKey: "value"))

    try store.rekey(.aes256(key: key))

    #expect(store.value(forKey: "value", as: String.self) == "payload")
    try copyFiles(of: store, in: rootDirectory, to: "reopened")
    let reopened = try makeStore(
      id: "reopened",
      rootDirectory: rootDirectory,
      encryption: .aes256(key: key)
    )
    #expect(reopened.value(forKey: "value", as: String.self) == "payload")
  }

  @Test(.requires(.encryption), arguments: [128, 300])
  func `Decrypting Fails While A Key Is Too Long For A Plain Store`(valueSize: Int) throws {
    // Upstream: UnitTest.cpp testDecryptToPlainKeyLimit
    let rootDirectory = temporaryRootDirectory()
    // Upstream's key is "plain-holder-test", 17 bytes, of which MMKV uses the first 16. The
    // package rejects a key longer than the cipher's instead, so the port passes those 16.
    let encryption = MMKVConfiguration.Encryption.aes128(key: "plain-holder-tes")
    let store = try makeStore(id: "decrypt", rootDirectory: rootDirectory, encryption: encryption)
    let key = String(repeating: "k", count: 65531)
    let value = String(repeating: "v", count: valueSize)
    #expect(store.set(value, forKey: key))
    #expect(store.set("intact", forKey: "ordinary"))

    // A plain store cannot hold this pair: its value needs a two-byte length prefix.
    expectError(.rekeyFailed) { try store.rekey(nil) }

    // The store is still encrypted with the old key, in memory and on disk.
    #expect(store.value(forKey: key, as: String.self) == value)
    #expect(store.value(forKey: "ordinary", as: String.self) == "intact")
    try copyFiles(of: store, in: rootDirectory, to: "after-failure")
    let reopened = try makeStore(
      id: "after-failure",
      rootDirectory: rootDirectory,
      encryption: encryption
    )
    #expect(reopened.value(forKey: key, as: String.self) == value)
    #expect(reopened.value(forKey: "ordinary", as: String.self) == "intact")

    let shorter = String(key.dropFirst())
    #expect(store.removeValue(forKey: key))
    #expect(store.set(value, forKey: shorter))
    try store.rekey(nil)

    #expect(store.value(forKey: shorter, as: String.self) == value)
    #expect(store.value(forKey: "ordinary", as: String.self) == "intact")
  }
}
