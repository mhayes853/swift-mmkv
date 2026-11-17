import Foundation
import SwiftMMKV
import Testing

/// Ports of the scenario tests in MMKV v2.4.3's `POSIX/demo/demo.cpp`. `MANIFEST.md` maps every
/// upstream function.
///
/// Many of upstream's scenarios only print what they read, or assert nothing and rely on not
/// crashing. The ports check the values upstream prints, and say where they check more.
@Suite(.requires(.store)) struct UpstreamDemoTests {
  // MARK: - Values

  @Test func `Every Value Type Round Trips And Survives A Reopen`() throws {
    // Upstream: demo.cpp functionalTest (and containerTest, which it calls)
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(id: "functional", rootDirectory: rootDirectory)

    #expect(FunctionalTest.write(to: store).allSatisfy { $0 })
    FunctionalTest.expectWritten(in: store)
    #expect(FunctionalTest.remove(from: store).allSatisfy { $0 })
    FunctionalTest.expectRemaining(in: store)

    // Upstream clears the memory cache and lists the keys again, then validates the file.
    let files = try copyFiles(of: store, in: rootDirectory, to: "reopened")
    #expect(files.isValid())
    FunctionalTest.expectRemaining(in: try makeStore(id: "reopened", rootDirectory: rootDirectory))
  }

  @Test(.requires(.readOnly))
  func `A Read Only Store Reads Everything And Refuses Writes`() throws {
    // Upstream: demo.cpp testReadOnly
    let rootDirectory = temporaryRootDirectory()
    let encryption = MMKVConfiguration.Encryption.aes128(key: "ReadOnly+Key")
    let store = try makeStore(id: "writer", rootDirectory: rootDirectory, encryption: encryption)
    #expect(FunctionalTest.write(to: store).allSatisfy { $0 })
    #expect(FunctionalTest.remove(from: store).allSatisfy { $0 })
    let files = try copyFiles(of: store, in: rootDirectory, to: "testReadOnly")
    for path in [files.dataPath, files.metadataPath] {
      try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path)
    }
    defer {
      for path in [files.dataPath, files.metadataPath] {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
      }
    }

    let readOnly = try makeStore(
      id: "testReadOnly",
      rootDirectory: rootDirectory,
      isReadOnly: true,
      encryption: encryption
    )
    FunctionalTest.expectRemaining(in: readOnly)

    // Upstream only checks that writing to a read-only store does not crash. The package
    // refuses every write and removal, and the contents stay as they were.
    #expect(FunctionalTest.write(to: readOnly).allSatisfy { !$0 })
    #expect(FunctionalTest.remove(from: readOnly).allSatisfy { !$0 })
    readOnly.removeAll()
    readOnly.trim()
    FunctionalTest.expectRemaining(in: readOnly)
    #expect(files.isValid())
  }

  @Test(.requires(.readOnly, .multiProcess))
  func `A Read Only Store Without Files Reads Nothing`() throws {
    // Upstream: demo.cpp testReadonlyCrash
    let rootDirectory = temporaryRootDirectory() + "/mmkv_readonly"

    let store = try makeStore(
      id: "UnitTestRo",
      rootDirectory: rootDirectory,
      mode: .multiProcess,
      isReadOnly: true
    )

    #expect(store.value(forKey: "test_ro_string", as: String.self) == nil)
    #expect(store.count == 0)
    // A read-only store creates neither its directory nor its files.
    #expect(!FileManager.default.fileExists(atPath: rootDirectory))
  }

  @Test func `Keys Longer Than 65531 Bytes Are Rejected Without Harm`() throws {
    // Upstream: demo.cpp testOversizedKey
    let store = try makeStore()

    let longest = String(repeating: "A", count: 65531)
    #expect(store.set("boundary_value", forKey: longest))
    #expect(store.value(forKey: longest, as: String.self) == "boundary_value")
    store.removeValue(forKey: longest)

    let tooLong = String(repeating: "B", count: 65532)
    #expect(!store.set("V", forKey: tooLong))
    #expect(store.value(forKey: tooLong, as: String.self) == nil)
    #expect(!store.set("V", forKey: String(repeating: "C", count: 70000)))

    #expect(store.set("world", forKey: "normal_key"))
    #expect(store.value(forKey: "normal_key", as: String.self) == "world")
  }

  // MARK: - Concurrency

  @Test func `Threads Writing Through Their Own Opens Keep Every Key`() async throws {
    // Upstream: demo.cpp threadTest
    let rootDirectory = temporaryRootDirectory()
    let keyCount = 10000
    let threadCount = 10

    await withTaskGroup(of: Void.self) { group in
      for thread in 0..<threadCount {
        group.addTask {
          // Each thread opens the store itself, as upstream's does.
          guard let store = try? makeStore(id: "thread_test1", rootDirectory: rootDirectory)
          else {
            Issue.record("Could not open the store")
            return
          }
          let segment = keyCount / threadCount
          for index in (segment * thread)..<(segment * (thread + 1)) {
            store.set(Int32(index), forKey: "int-\(index)")
            store.set("str-\(index)", forKey: "string-\(index)")
          }
        }
      }
    }

    let store = try makeStore(id: "thread_test1", rootDirectory: rootDirectory)
    #expect(store.count == 2 * keyCount)
    for index in stride(from: 0, to: keyCount, by: 97) {
      #expect(store.value(forKey: "int-\(index)", as: Int32.self) == Int32(index))
      #expect(store.value(forKey: "string-\(index)", as: String.self) == "str-\(index)")
    }
  }

  // MARK: - File sizes

  @Test(.requires(.multiProcess, .encryption))
  func `A Value That Exactly Fills The First Page Survives A Trim`() throws {
    // Upstream: demo.cpp cornetSizeTest
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(
      id: "cornerSize",
      rootDirectory: rootDirectory,
      mode: .multiProcess,
      encryption: .aes128(key: "aes")
    )
    store.removeAll()
    // Upstream's accounting of a page: less 2, less 4 for the data file's header, less 4 for the
    // key and its length, and less 3 for the value's length prefix.
    let value = [UInt8](repeating: 0x5A, count: pageSize - 2 - 4 - (3 + 1) - 3)

    #expect(store.set(value, forKey: "key"))
    store.trim()

    // Upstream asserts nothing: it checks this does not crash or corrupt the file.
    #expect(store.value(forKey: "key", as: [UInt8].self) == value)
    let files = try copyFiles(of: store, in: rootDirectory, to: "reopened")
    #expect(files.isValid())
    let reopened = try makeStore(
      id: "reopened",
      rootDirectory: rootDirectory,
      mode: .multiProcess,
      encryption: .aes128(key: "aes")
    )
    #expect(reopened.value(forKey: "key", as: [UInt8].self) == value)
  }

  @Test(.requires(.multiProcess, .encryption))
  func `Setting And Removing A Sixteenth Of A Page Keeps The File Valid`() throws {
    // Upstream: demo.cpp fastRemoveCornetSizeTest
    let rootDirectory = temporaryRootDirectory()
    let encryption = MMKVConfiguration.Encryption.aes128(key: "aes")
    let store = try makeStore(
      id: "fastRemoveCornerSize",
      rootDirectory: rootDirectory,
      mode: .multiProcess,
      encryption: encryption
    )
    store.removeAll()
    // Sixteen set-and-remove pairs come to just under a page, so the last ones force a full
    // write-back, which is where upstream once corrupted the file.
    let size = (pageSize - 4 - 4 - 4 - 3 - (3 + 1 + 1)) / 16
    let value = [UInt8](repeating: UInt8(ascii: "A"), count: size)

    for _ in 0..<16 {
      #expect(store.set(value, forKey: "key"))
      #expect(store.removeValue(forKey: "key"))
    }

    // Upstream asserts nothing here.
    #expect(store.count == 0)
    #expect(store.set(value, forKey: "key"))
    let files = try copyFiles(of: store, in: rootDirectory, to: "reopened")
    #expect(files.isValid())
    let reopened = try makeStore(
      id: "reopened",
      rootDirectory: rootDirectory,
      mode: .multiProcess,
      encryption: encryption
    )
    #expect(reopened.value(forKey: "key", as: [UInt8].self) == value)
    #expect(reopened.count == 1)
  }

  @Test func `A Single Bool Survives A Reload`() throws {
    // Upstream: demo.cpp itemSizeHolderTest
    try expectSingleBoolSurvivesReload(encryption: nil)
  }

  @Test(.requires(.encryption)) func `A Single Encrypted Bool Survives A Reload`() throws {
    // Upstream: demo.cpp itemSizeHolderTest
    try expectSingleBoolSurvivesReload(encryption: .aes128(key: "cryptKey"))
  }

  private func expectSingleBoolSurvivesReload(encryption: MMKVConfiguration.Encryption?) throws {
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(id: "itemsize", rootDirectory: rootDirectory, encryption: encryption)

    #expect(store.set(true, forKey: "bool"))

    // Upstream's comment says "you won't find the key", describing a bug in reading back a
    // file whose only pair is this short. It asserts nothing; the port checks the bug is gone.
    try copyFiles(of: store, in: rootDirectory, to: "reloaded")
    let reloaded = try makeStore(
      id: "reloaded",
      rootDirectory: rootDirectory,
      encryption: encryption
    )
    #expect(reloaded.keys == ["bool"])
    #expect(reloaded.value(forKey: "bool", as: Bool.self) == true)
  }

  @Test(arguments: [(0, 1), (pageSize + 1, 2), (pageSize / 2, 1)])
  func `The Expected Capacity Sets The Initial File Size In Whole Pages`(
    capacity: Int,
    pages: Int
  ) throws {
    // Upstream: demo.cpp testExpectedCapacity
    let rootDirectory = temporaryRootDirectory()

    let store = try makeStore(
      id: "testExpectedCapacity",
      rootDirectory: rootDirectory,
      expectedCapacity: capacity
    )

    _ = store.count
    let files = StoreFiles(id: store.id, rootDirectory: rootDirectory)
    #expect(try files.dataFileSize() == pages * pageSize)
  }

  @Test func `Reopening With A Larger Expected Capacity Grows The File But Never Shrinks It`()
    throws
  {
    // Upstream: demo.cpp testExpectedCapacity
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(id: "testExpectedCapacity3", rootDirectory: rootDirectory)
    store.removeAll()
    #expect(try StoreFiles(id: store.id, rootDirectory: rootDirectory).dataFileSize() == pageSize)

    let grown = try copyFiles(of: store, in: rootDirectory, to: "grown")
    let grownStore = try makeStore(
      id: grown.id,
      rootDirectory: rootDirectory,
      expectedCapacity: 100 * pageSize + 100
    )
    _ = grownStore.count
    #expect(try grown.dataFileSize() == 101 * pageSize)

    let reopened = try copyFiles(of: grownStore, in: rootDirectory, to: "reopened")
    _ = try makeStore(id: reopened.id, rootDirectory: rootDirectory, expectedCapacity: 0).count
    #expect(try reopened.dataFileSize() == 101 * pageSize)
  }

  @Test func `An Expected Capacity Of The Pairs' Size Needs No Growth`() throws {
    // Upstream: demo.cpp testExpectedCapacity
    let rootDirectory = temporaryRootDirectory()
    let value = "🏊🏻®4️⃣🐅_" + String(repeating: "0", count: 10000)
    let pairSize = 3 + value.utf8.count

    // Upstream's comments say neither store grows. It asserts nothing; the port checks that.
    let one = try makeStore(
      id: "testExpectedCapacity4",
      rootDirectory: rootDirectory,
      expectedCapacity: pairSize
    )
    let oneFiles = StoreFiles(id: one.id, rootDirectory: rootDirectory)
    _ = one.count
    let oneSize = try oneFiles.dataFileSize()
    #expect(one.set(value, forKey: "key"))
    #expect(try oneFiles.dataFileSize() == oneSize)

    let ten = try makeStore(
      id: "testExpectedCapacity5",
      rootDirectory: rootDirectory,
      expectedCapacity: pairSize * 10
    )
    let tenFiles = StoreFiles(id: ten.id, rootDirectory: rootDirectory)
    _ = ten.count
    let tenSize = try tenFiles.dataFileSize()
    for letter in "abcdefghij" {
      #expect(ten.set(value, forKey: "\(letter)ey"))
    }
    #expect(try tenFiles.dataFileSize() == tenSize)
    #expect(ten.count == 10)
  }

  // MARK: - Clearing

  @Test func `Clearing A Store Twice`() throws {
    // Upstream: demo.cpp testClearEmptyMMKV
    let store = try makeStore(id: "emptyMMKV")
    #expect(store.set(true, forKey: "bool"))

    store.removeAll()
    store.removeAll()

    #expect(store.count == 0)
    #expect(store.set(true, forKey: "bool"))
    #expect(store.count == 1)
  }

  @Test func `Clearing While Keeping Capacity Keeps The File Size`() throws {
    // Upstream: demo.cpp testClearAllKeepSpace
    try expectClearingWhileKeepingCapacity(encryption: nil)
  }

  @Test(.requires(.encryption))
  func `Clearing An Encrypted Store While Keeping Capacity Keeps The File Size`() throws {
    // Upstream: demo.cpp testClearAllKeepSpace
    try expectClearingWhileKeepingCapacity(encryption: .aes128(key: "cryptKey111"))
  }

  private func expectClearingWhileKeepingCapacity(
    encryption: MMKVConfiguration.Encryption?
  ) throws {
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(
      id: "testClearAllKeepSpace",
      rootDirectory: rootDirectory,
      encryption: encryption
    )
    let files = StoreFiles(id: store.id, rootDirectory: rootDirectory)
    for index in 0..<100 {
      store.set(String(repeating: "0", count: 10), forKey: "\(index)")
    }
    let size = try files.dataFileSize()

    store.removeAll(keepingCapacity: true)

    #expect(try files.dataFileSize() == size)
    #expect(store.count == 0)
    #expect(store.set(Int32(123), forKey: "key1"))
    #expect(store.value(forKey: "key1", as: Int32.self) == 123)
    #expect(store.set(Int32(456), forKey: "key2"))
    #expect(store.value(forKey: "key2", as: Int32.self) == 456)

    #expect(store.count == 2)
    store.removeAll()
    #expect(store.count == 0)

    store.set(Int32(1234), forKey: "key1")
    store.set(Int32(12345), forKey: "key2")
    store.removeAll(keepingCapacity: true)
    try copyFiles(of: store, in: rootDirectory, to: "reopened")
    let reopened = try makeStore(
      id: "reopened",
      rootDirectory: rootDirectory,
      encryption: encryption
    )
    #expect(reopened.count == 0)
    #expect(reopened.set(Int32(456), forKey: "key2"))
    #expect(reopened.value(forKey: "key2", as: Int32.self) == 456)
  }

  // MARK: - Expiration

  @Test(.requires(.expiry)) func `Values That Never Expire Outlive Expiring Ones`() async throws {
    // Upstream: demo.cpp testAutoExpiration
    let store = try makeStore(id: "testAutoExpire", recovery: .recover)
    store.removeAll()
    store.trim()

    // Upstream writes this key before expiration is enabled and relies on the store's default
    // duration of one second, which the package cannot set; the port gives the key its own.
    #expect(store.set(true, forKey: "auto_expire_key_1", expiringIn: .seconds(1)))
    #expect(store.set("never_expire_value_1", forKey: "never_expire_key_1"))
    #expect(store.set("", forKey: "never_expire_key_2"))
    #expect(store.set([UInt8](), forKey: "never_expire_key_3"))
    try await Task.sleep(for: oneSecondExpiry)

    #expect(!store.contains("auto_expire_key_1"))
    #expect(store.contains("never_expire_key_1"))
    #expect(store.contains("never_expire_key_2"))
    #expect(store.contains("never_expire_key_3"))
    // Empty values that never expire are still there, and empty.
    #expect(store.value(forKey: "never_expire_key_2", as: String.self) == "")
    #expect(store.value(forKey: "never_expire_key_3", as: [UInt8].self) == [])
    #expect(store.count == 3)
    #expect(store.keys == ["never_expire_key_1", "never_expire_key_2", "never_expire_key_3"])
  }

  @Test(.requires(.expiry)) func `A Key Set Again After Its Removal Takes Its New Expiry`()
    async throws
  {
    // Upstream: demo.cpp testAutoExpiration
    let store = try makeStore(id: "testAutoExpire", recovery: .recover)
    try enableExpiration(on: store)
    #expect(store.set("never_expire_value_1", forKey: "never_expire_key_1"))
    #expect(store.set(true, forKey: "auto_expire_key_1", expiringIn: .seconds(3600)))

    #expect(store.removeValue(forKey: "never_expire_key_1"))
    #expect(store.set("never_expire_value_1", forKey: "never_expire_key_1"))
    #expect(store.set(true, forKey: "auto_expire_key_1", expiringIn: .seconds(1)))
    try await Task.sleep(for: oneSecondExpiry)

    #expect(store.contains("never_expire_key_1"))
    #expect(!store.contains("auto_expire_key_1"))
    #expect(store.count == 1)
    #expect(store.keys == ["never_expire_key_1"])
  }

  // MARK: - Overwriting

  @Test func `Overwriting One Key Over And Over`() throws {
    // Upstream: demo.cpp testOnlyOneKey
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(id: "testOneKey", rootDirectory: rootDirectory)
    let key = "name"
    #expect(store.value(forKey: key, as: String.self) == nil)

    #expect(store.set("world", forKey: key))
    #expect(store.value(forKey: key, as: String.self) == "world")
    for index in 0..<10 {
      #expect(store.set("world_\(index)", forKey: key))
      #expect(store.value(forKey: key, as: String.self) == "world_\(index)")
    }
    // A value large enough to grow the file.
    let bigValue = String(repeating: "0", count: 100_000)
    #expect(store.set(bigValue, forKey: key))
    #expect(store.value(forKey: key, as: String.self) == bigValue)
    #expect(store.set("OK", forKey: key))
    #expect(store.value(forKey: key, as: String.self) == "OK")

    try copyFiles(of: store, in: rootDirectory, to: "reopened")
    let reopened = try makeStore(id: "reopened", rootDirectory: rootDirectory)
    #expect(reopened.value(forKey: key, as: String.self) == "OK")
  }

  @Test(.requires(.encryption)) func `Overwriting One Encrypted Key Over And Over`() throws {
    // Upstream: demo.cpp testOnlyOneKey
    try expectOverwritingOneEncryptedKey(
      encryption: .aes128(key: "fastest"),
      expiry: nil,
      prefix: "cryptworld"
    )
  }

  @Test(.requires(.encryption, .expiry))
  func `Overwriting One Encrypted Expiring Key Over And Over`() throws {
    // Upstream: demo.cpp testOnlyOneKey
    try expectOverwritingOneEncryptedKey(
      encryption: .aes128(key: "expiretest"),
      expiry: .seconds(24 * 60 * 60),
      prefix: "expire"
    )
  }

  /// Upstream's encrypted scenarios of `testOnlyOneKey`. For the expiring one, upstream gives the
  /// store a default expiry of a day, which the package cannot, so each write passes it instead.
  private func expectOverwritingOneEncryptedKey(
    encryption: MMKVConfiguration.Encryption,
    expiry: Duration?,
    prefix: String
  ) throws {
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(
      id: "testOneKeyCrypt",
      rootDirectory: rootDirectory,
      encryption: encryption
    )
    let key = "name"
    #expect(store.value(forKey: key, as: String.self) == nil)

    #expect(store.set(prefix, forKey: key, expiringIn: expiry.map { _ in .seconds(1000) }))
    #expect(store.value(forKey: key, as: String.self) == prefix)
    for index in 0..<10 {
      #expect(store.set("\(prefix)_\(index)", forKey: key, expiringIn: expiry))
      #expect(store.value(forKey: key, as: String.self) == "\(prefix)_\(index)")
    }

    try copyFiles(of: store, in: rootDirectory, to: "reopened")
    let reopened = try makeStore(
      id: "reopened",
      rootDirectory: rootDirectory,
      encryption: encryption
    )
    #expect(reopened.value(forKey: key, as: String.self) == "\(prefix)_9")
    if expiry == nil {
      #expect(reopened.set("cryptworld_good", forKey: key))
      #expect(reopened.value(forKey: key, as: String.self) == "cryptworld_good")
    }
  }

  @Test func `Setting And Removing Keys Then Reopening`() throws {
    // Upstream: demo.cpp testOverride
    try expectSettingAndRemovingKeys(encryption: nil, expiry: nil)
  }

  @Test(.requires(.encryption, .expiry))
  func `Setting And Removing Encrypted Expiring Keys Then Reopening`() throws {
    // Upstream: demo.cpp testOverride
    try expectSettingAndRemovingKeys(
      encryption: .aes128(key: "fastest2"),
      expiry: .seconds(24 * 60 * 60)
    )
  }

  /// Upstream's `testOverride`. For the encrypted scenario, upstream gives the store a default
  /// expiry of a day, which the package cannot, so each write passes it instead.
  private func expectSettingAndRemovingKeys(
    encryption: MMKVConfiguration.Encryption?,
    expiry: Duration?
  ) throws {
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(
      id: "testOverride",
      rootDirectory: rootDirectory,
      encryption: encryption
    )

    #expect(store.set("world1", forKey: "key1", expiringIn: expiry))
    #expect(store.value(forKey: "key1", as: String.self) == "world1")
    #expect(store.set("world2", forKey: "key2", expiringIn: expiry))
    #expect(store.value(forKey: "key2", as: String.self) == "world2")
    store.removeValue(forKey: "key1")
    store.removeValue(forKey: "key2")

    #expect(store.set("world3", forKey: "key3", expiringIn: expiry))
    #expect(store.value(forKey: "key3", as: String.self) == "world3")
    store.removeValue(forKey: "key3")

    // A value large enough to grow the file.
    let bigValue = String(repeating: "0", count: 100_000)
    #expect(store.set(bigValue, forKey: "key1", expiringIn: expiry))
    #expect(store.value(forKey: "key1", as: String.self) == bigValue)
    store.removeValue(forKey: "key1")

    #expect(store.set("OK", forKey: "key2", expiringIn: expiry))
    #expect(store.value(forKey: "key2", as: String.self) == "OK")

    try copyFiles(of: store, in: rootDirectory, to: "reopened")
    let reopened = try makeStore(
      id: "reopened",
      rootDirectory: rootDirectory,
      encryption: encryption
    )
    #expect(reopened.value(forKey: "key2", as: String.self) == "OK")
    #expect(reopened.keys == ["key2"])

    reopened.removeValue(forKey: "key2")
    reopened.trim()
    #expect(reopened.count == 0)
  }

  // MARK: - Compare before set

  @Test func `Setting An Identical Value Writes Nothing`() throws {
    // Upstream: demo.cpp testCompareBeforeSet
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(
      id: "testCompareBeforeSet",
      rootDirectory: rootDirectory,
      compareBeforeSet: true
    )
    let files = StoreFiles(id: store.id, rootDirectory: rootDirectory)
    func actualSize() throws -> UInt32 { try files.metadata().actualSize }
    #expect(store.set("extraValue", forKey: "extraKey"))

    /// Sets `value` twice, expecting the second write to leave the file alone, then sets
    /// `other`, expecting it to be read back.
    func expectComparedBeforeSet<V: MMKVValue & Equatable>(
      _ value: V,
      then other: V,
      forKey key: String,
      sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
      store.set(value, forKey: key)
      let size = try actualSize()
      #expect(store.value(forKey: key, as: V.self) == value, sourceLocation: sourceLocation)
      store.set(value, forKey: key)
      #expect(try actualSize() == size, sourceLocation: sourceLocation)
      store.set(other, forKey: key)
      #expect(store.value(forKey: key, as: V.self) == other, sourceLocation: sourceLocation)
    }

    try expectComparedBeforeSet(true, then: false, forKey: "bool")
    try expectComparedBeforeSet(Int32(12345), then: Int32(12345 << 1), forKey: "int32_t")
    try expectComparedBeforeSet(UInt32(6379), then: UInt32(6379 >> 1), forKey: "uint32_t")
    try expectComparedBeforeSet(Int64(8080), then: Int64(8080 >> 1), forKey: "int64_t")
    try expectComparedBeforeSet(UInt64(8848), then: UInt64(8848 >> 1), forKey: "uint64_t")
    let float: Float = -987.012
    try expectComparedBeforeSet(float, then: float * 12.56, forKey: "float")
    // Upstream initializes the double from a float literal and multiplies it by one.
    let double = Double(Float(8888987.012))
    try expectComparedBeforeSet(double, then: double * Double(Float(-12.56)), forKey: "double")
    try expectComparedBeforeSet("🏊🏻®4️⃣🐅_", then: "12🏊🏻e®4️⃣🐅_34)(*()", forKey: "char*")
    let s1 = "🏊🏻®hhh4️⃣🐅_yyy"
    let s2 = "0aA🏊🏻®hhh4️⃣🐅_zzz"
    try expectComparedBeforeSet(s1, then: s2, forKey: "string")
    let buffer1 = Array("buffer_🏊🏻®hhh4️⃣🐅_yyy".utf8)
    let buffer2 = Array("buffer_0aA🏊🏻®hhh4️⃣🐅_zzz".utf8)
    try expectComparedBeforeSet(buffer1, then: buffer2, forKey: "mmbuffer")
    #expect(store.value(forKey: "mmbuffer", as: String.self) == "buffer_0aA🏊🏻®hhh4️⃣🐅_zzz")
    let bufferString1 = String(decoding: buffer1, as: UTF8.self)
    let bufferString2 = String(decoding: buffer2, as: UTF8.self)
    try expectComparedBeforeSet(
      ["1", bufferString1, bufferString2],
      then: ["2", bufferString1, bufferString2],
      forKey: "string<vector>"
    )
  }

  @Test func `A Value Of Another Type Is Never Taken For An Identical One`() throws {
    // Upstream: demo.cpp testCompareBeforeSet
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(
      id: "differentType2",
      rootDirectory: rootDirectory,
      compareBeforeSet: true
    )
    let files = StoreFiles(id: store.id, rootDirectory: rootDirectory)
    func actualSize() throws -> UInt32 { try files.metadata().actualSize }
    store.removeAll()
    store.set("xxx", forKey: "yyy")
    var size = try actualSize()

    /// Expects `write` to append to the file.
    func expectGrows(
      _ write: () -> Void,
      sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
      write()
      let newSize = try actualSize()
      #expect(newSize > size, sourceLocation: sourceLocation)
      size = newSize
    }

    try expectGrows { store.set("value1", forKey: "key1") }
    // A string read as a bool: its first byte, the length 6, is not zero.
    #expect(store.value(forKey: "key1", as: Bool.self) == true)
    try expectGrows { store.set(true, forKey: "key1") }
    try expectGrows { store.set(false, forKey: "key1") }
    try expectGrows { store.set("value1", forKey: "key1") }
    #expect(store.value(forKey: "key1", as: String.self) == "value1")

    let s1 = "🏊🏻®hhh4️⃣🐅_yyy"
    let s2 = "0aA🏊🏻®hhh4️⃣🐅_zzz"
    try expectGrows { store.set(["1", s1, s2], forKey: "key1") }
    #expect(store.value(forKey: "key1", as: [String].self) == ["1", s1, s2])

    // Comparing the new string with the old integer fails to decode, which upstream logs, and the
    // write goes ahead.
    store.set(Int32(12345), forKey: "key2")
    size = try actualSize()
    try expectGrows { store.set("abcdefg", forKey: "key2") }
    #expect(store.value(forKey: "key2", as: String.self) == "abcdefg")
  }

  @Test func `Setting An Identical Empty String Writes Nothing`() throws {
    // Upstream: demo.cpp testCompareBeforeSet
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(
      id: "compareEmpty",
      rootDirectory: rootDirectory,
      compareBeforeSet: true
    )
    let files = StoreFiles(id: store.id, rootDirectory: rootDirectory)

    store.set("", forKey: "key")
    let size = try files.metadata().actualSize
    store.set("", forKey: "key")
    #expect(try files.metadata().actualSize == size)

    store.set("abcdefG", forKey: "key")
    #expect(try files.metadata().actualSize > size)
    #expect(store.value(forKey: "key", as: String.self) == "abcdefG")
  }

  // MARK: - Encryption

  @Test(.requires(.encryption)) func `Rekeying Through Every Cipher Keeps Every Value`() throws {
    // Upstream: demo.cpp testReKey
    let rootDirectory = temporaryRootDirectory()
    // Upstream's identifier is "test/AES_reKey1". MMKV names the files of an identifier with a
    // slash after its MD5, and these ports find files by identifier, so the slash is dropped.
    let store = try makeStore(id: "AES_reKey1", rootDirectory: rootDirectory)
    #expect(FunctionalTest.write(to: store).allSatisfy { $0 })
    #expect(FunctionalTest.remove(from: store).allSatisfy { $0 })
    var reopenings = 0

    func expectReadable(with encryption: MMKVConfiguration.Encryption?) throws {
      FunctionalTest.expectRemaining(in: store)
      reopenings += 1
      try copyFiles(of: store, in: rootDirectory, to: "reopened-\(reopenings)")
      let reopened = try makeStore(
        id: "reopened-\(reopenings)",
        rootDirectory: rootDirectory,
        encryption: encryption
      )
      FunctionalTest.expectRemaining(in: reopened)
    }

    try store.rekey(.aes128(key: "Key_seq_1"))
    try expectReadable(with: .aes128(key: "Key_seq_1"))

    try store.rekey(.aes256(key: "Key_Seq_Very_Looooooooong"))
    try expectReadable(with: .aes256(key: "Key_Seq_Very_Looooooooong"))

    try store.rekey(nil)
    try expectReadable(with: nil)
  }
}

/// Upstream's `functionalTest` and the part of `containerTest` the package can store, which
/// `testReadOnly` and `testReKey` reuse.
private enum FunctionalTest {
  static let rawString = "Hello, MMKV-示例 for POSIX"
  static let string = "Hello, MMKV-示例 for POSIX string"
  /// `string_view(string).substr(7, 21)`, which counts UTF-8 bytes.
  static let stringView = String(decoding: Array(string.utf8)[7..<28], as: UTF8.self)
  static let stringSet = ["Hello", "MMKV-示例", "for", "POSIX"]

  /// The keys left once ``remove(from:)`` has run.
  static let remainingKeys: Set<String> = [
    "int32", "uint32", "int64", "uint64", "float", "double", "raw_string", "string", "string_view",
    "string-set",
  ]

  /// The writes, returning whether each succeeded.
  static func write(to store: MMKVStore) -> [Bool] {
    [
      store.set(true, forKey: "bool"),
      store.set(Int32(1024), forKey: "int32"),
      store.set(UInt32.max, forKey: "uint32"),
      store.set(Int64.min, forKey: "int64"),
      store.set(UInt64.max, forKey: "uint64"),
      store.set(Float(3.14), forKey: "float"),
      store.set(Double.greatestFiniteMagnitude, forKey: "double"),
      store.set(self.rawString, forKey: "raw_string"),
      store.set(self.string, forKey: "string"),
      store.set(self.stringView, forKey: "string_view"),
      store.set(self.stringSet, forKey: "string-set"),
    ]
  }

  /// The removals that follow, returning whether each write and removal succeeded.
  static func remove(from store: MMKVStore) -> [Bool] {
    var results = [store.removeValue(forKey: "bool")]
    store.removeValues(forKeys: ["int", "long"])
    results.append(store.set("some string", forKey: "null string"))
    // Upstream sets a null C string, which removes the key.
    results.append(store.removeValue(forKey: "null string"))
    return results
  }

  static func expectWritten(
    in store: MMKVStore,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(store.value(forKey: "bool", as: Bool.self) == true, sourceLocation: sourceLocation)
    self.expectValues(in: store, sourceLocation: sourceLocation)
    #expect(store.keys == self.remainingKeys.union(["bool"]), sourceLocation: sourceLocation)
    #expect(store.count == self.remainingKeys.count + 1, sourceLocation: sourceLocation)
    #expect(store.contains("string"), sourceLocation: sourceLocation)
  }

  static func expectRemaining(
    in store: MMKVStore,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(store.value(forKey: "bool", as: Bool.self) == nil, sourceLocation: sourceLocation)
    #expect(
      store.value(forKey: "null string", as: String.self) == nil,
      sourceLocation: sourceLocation
    )
    self.expectValues(in: store, sourceLocation: sourceLocation)
    #expect(store.keys == self.remainingKeys, sourceLocation: sourceLocation)
  }

  private static func expectValues(in store: MMKVStore, sourceLocation: SourceLocation) {
    #expect(store.value(forKey: "int32", as: Int32.self) == 1024, sourceLocation: sourceLocation)
    #expect(store.value(forKey: "uint32", as: UInt32.self) == .max, sourceLocation: sourceLocation)
    #expect(store.value(forKey: "int64", as: Int64.self) == .min, sourceLocation: sourceLocation)
    #expect(store.value(forKey: "uint64", as: UInt64.self) == .max, sourceLocation: sourceLocation)
    #expect(store.value(forKey: "float", as: Float.self) == 3.14, sourceLocation: sourceLocation)
    #expect(
      store.value(forKey: "double", as: Double.self) == .greatestFiniteMagnitude,
      sourceLocation: sourceLocation
    )
    #expect(
      store.value(forKey: "raw_string", as: String.self) == self.rawString,
      sourceLocation: sourceLocation
    )
    #expect(
      store.value(forKey: "string", as: String.self) == self.string,
      sourceLocation: sourceLocation
    )
    #expect(
      store.value(forKey: "string_view", as: String.self) == "MMKV-示例 for POSIX",
      sourceLocation: sourceLocation
    )
    #expect(
      store.value(forKey: "string-set", as: [String].self) == self.stringSet,
      sourceLocation: sourceLocation
    )
  }
}
