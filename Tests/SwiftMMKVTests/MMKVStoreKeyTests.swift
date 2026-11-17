import Foundation
import SwiftMMKV
import Testing

@Suite(.requires(.store)) struct MMKVStoreKeyTests {
  @Test func `Reports Keys Count And Containment`() throws {
    let store = try makeStore()
    #expect(store.keys.isEmpty)
    #expect(store.count == 0)

    store.set(1.0, forKey: "a")
    store.set("two", forKey: "b")

    #expect(store.keys == ["a", "b"])
    #expect(store.count == 2)
    #expect(store.contains("a"))
    #expect(!store.contains("c"))
  }

  @Test func `Removes A Single Key`() throws {
    let store = try makeStore()
    store.set(1.0, forKey: "a")
    store.set(2.0, forKey: "b")

    #expect(store.removeValue(forKey: "a"))

    #expect(store.keys == ["b"])
    #expect(store.value(forKey: "a", as: Double.self) == nil)
  }

  @Test func `Removes Several Keys At Once`() throws {
    let store = try makeStore()
    for key in ["a", "b", "c", "d"] {
      store.set(key, forKey: key)
    }

    store.removeValues(forKeys: ["a", "c", "missing"])

    #expect(store.keys == ["b", "d"])
  }

  @Test(arguments: [false, true])
  func `Removes Everything`(keepingCapacity: Bool) throws {
    let store = try makeStore()
    for index in 0..<100 {
      store.set(Double(index), forKey: "key\(index)")
    }

    store.removeAll(keepingCapacity: keepingCapacity)

    #expect(store.keys.isEmpty)
    #expect(store.count == 0)
    #expect(store.set("again", forKey: "key"))
    #expect(store.value(forKey: "key", as: String.self) == "again")
  }

  @Test(arguments: [false, true])
  func `Removes The Keys Matching A Predicate`(keepingCapacity: Bool) throws {
    let store = try makeStore()
    store.set(1.0, forKey: "cache.a")
    store.set(2.0, forKey: "cache.b")
    store.set(3.0, forKey: "settings.volume")

    store.removeAll(keepingCapacity: keepingCapacity) { $0.hasPrefix("cache.") }

    #expect(store.keys == ["settings.volume"])
    #expect(store.value(forKey: "settings.volume", as: Double.self) == 3)
  }

  @Test func `Reports The Size Of Its File And Of The Data In It`() throws {
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(rootDirectory: rootDirectory)
    let path = "\(rootDirectory)/\(MMKVConfiguration.defaultID)"
    #expect(store.byteSize == (try fileSize(atPath: path)))
    #expect(store.byteSize > 0)
    let emptySize = store.byteSize
    let emptyUsedSize = store.usedByteSize

    for index in 0..<64 {
      store.set(String(repeating: "x", count: 16_384), forKey: "blob\(index)")
    }
    #expect(store.byteSize == (try fileSize(atPath: path)))
    #expect(store.byteSize > emptySize)
    #expect(store.usedByteSize >= 64 * 16_384)
    #expect(store.usedByteSize <= store.byteSize)

    store.removeAll()
    #expect(store.byteSize == emptySize)
    #expect(store.usedByteSize == emptyUsedSize)
  }

  @Test func `Trimming After A Filtered Removal Shrinks The File`() throws {
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(rootDirectory: rootDirectory)
    let path = "\(rootDirectory)/\(MMKVConfiguration.defaultID)"
    for index in 0..<64 {
      store.set(String(repeating: "x", count: 16_384), forKey: "blob\(index)")
    }
    store.set("kept", forKey: "kept")
    let grownSize = try fileSize(atPath: path)

    store.removeAll(keepingCapacity: true) { $0.hasPrefix("blob") }
    #expect(try fileSize(atPath: path) == grownSize)

    store.set(String(repeating: "x", count: 16_384), forKey: "blob")
    store.removeAll { $0.hasPrefix("blob") }

    #expect(try fileSize(atPath: path) < grownSize)
    #expect(store.keys == ["kept"])
  }

  @Test func `A Throwing Predicate Removes Nothing And Releases The Lock`() throws {
    struct Failure: Error, Equatable {}
    let store = try makeStore()
    store.set(1.0, forKey: "a")

    #expect(throws: Failure()) {
      try store.removeAll { _ throws(Failure) in throw Failure() }
    }

    #expect(store.keys == ["a"])
    // A leaked lock would deadlock this write from another thread.
    let thread = Thread { store.set(2.0, forKey: "b") }
    thread.start()
    while !thread.isFinished { usleep(1000) }
    #expect(store.keys == ["a", "b"])
  }

  @Test func `Stores Opened Over The Same Files Share Their Contents`() throws {
    let rootDirectory = temporaryRootDirectory()
    let first = try makeStore(id: "shared", rootDirectory: rootDirectory)
    let second = try makeStore(id: "shared", rootDirectory: rootDirectory)
    let other = try makeStore(id: "other", rootDirectory: rootDirectory)

    first.set("value", forKey: "key")

    #expect(second.value(forKey: "key", as: String.self) == "value")
    #expect(other.value(forKey: "key", as: String.self) == nil)
    #expect(second.id == "shared")
  }

  @Test func `Creates The Store's Files In Its Root Directory`() throws {
    let rootDirectory = temporaryRootDirectory() + "/nested/mmkv"
    let store = try makeStore(id: "files", rootDirectory: rootDirectory)

    store.set("value", forKey: "key")

    #expect(FileManager.default.fileExists(atPath: "\(rootDirectory)/files"))
    #expect(FileManager.default.fileExists(atPath: "\(rootDirectory)/files.crc"))
  }

  @Test func `Describes Itself With Its Identifier And Sorted Keys`() throws {
    let store = try makeStore(id: "described")
    store.set(1.0, forKey: "volume")
    store.set("blob", forKey: "username")

    #expect(store.description == "MMKV (described): [username, volume]")
    #expect(
      String(decoding: store.toJSON(), as: UTF8.self) == #"{"described":["username","volume"]}"#
    )
  }

  @Test func `Escapes Keys In JSON`() throws {
    let store = try makeStore(id: "escaped")
    store.set(1.0, forKey: "quote\"back\\slash\nnew\u{1}line é")

    let json = store.toJSON()

    #expect(
      String(decoding: json, as: UTF8.self)
        == #"{"escaped":["quote\"back\\slash\nnew\u0001line é"]}"#
    )
    let parsed = try JSONSerialization.jsonObject(with: Data(json)) as? [String: [String]]
    #expect(parsed == ["escaped": ["quote\"back\\slash\nnew\u{1}line é"]])
  }

  @Test func `Opening Fails For An Empty Identifier Or Root Directory`() throws {
    let unused = MMKVDirectory(path: "/tmp/unused")
    #expect(throws: MMKVError.openFailed(id: "", directory: unused)) {
      try MMKVStore(MMKVConfiguration(id: "", directory: unused, mode: .singleProcess))
    }
    let empty = MMKVDirectory(path: "")
    #expect(throws: MMKVError.openFailed(id: "id", directory: empty)) {
      try MMKVStore(MMKVConfiguration(id: "id", directory: empty, mode: .singleProcess))
    }
  }

  @Test func `With Exclusive Lock Makes A Read Modify Write Atomic`() async throws {
    let store = try makeStore()
    store.set(0.0, forKey: "counter")

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<8 {
        group.addTask {
          for _ in 0..<500 {
            store.withExclusiveLock { store in
              let count = store.value(forKey: "counter", as: Double.self) ?? 0
              store.set(count + 1, forKey: "counter")
            }
          }
        }
      }
    }

    #expect(store.value(forKey: "counter", as: Double.self) == 4000)
  }

  @Test func `With Exclusive Lock Is Reentrant And Returns The Body's Result`() throws {
    let store = try makeStore()

    let result = store.withExclusiveLock { store in
      store.withExclusiveLock { store in
        store.set("nested", forKey: "key")
        return store.count
      }
    }

    #expect(result == 1)
  }
}

private func fileSize(atPath path: String) throws -> Int {
  try #require(FileManager.default.attributesOfItem(atPath: path)[.size] as? Int)
}
