import Foundation
import SwiftMMKV
import Testing

@Suite struct MMKVDirectoryTests {
  @Test func `The React Native Directory On Android Is The Files Directory's mmkv Directory`() {
    #expect(
      MMKVDirectory.reactNative(filesDirectory: "/data/user/0/app/files")
        == MMKVDirectory(path: "/data/user/0/app/files/mmkv")
    )
    #expect(
      MMKVDirectory.reactNative(filesDirectory: "/data/user/0/app/files/")
        == MMKVDirectory(path: "/data/user/0/app/files/mmkv")
    )
  }
}

@Suite struct MMKVDirectoryStoreTests {
  /// Creates a store's files without opening it in this process, by copying those of a store
  /// that is open under another identifier.
  private func makeUnopenedStore(id: String, in rootDirectory: String) throws {
    let source = try makeStore(id: "source-\(id)", rootDirectory: rootDirectory)
    source.set("value", forKey: "key")
    for suffix in ["", ".crc"] {
      try FileManager.default.copyItem(
        atPath: "\(rootDirectory)/source-\(id)\(suffix)",
        toPath: "\(rootDirectory)/\(id)\(suffix)"
      )
    }
  }

  @Test func `Contains A Store Once Its Files Exist`() throws {
    let rootDirectory = temporaryRootDirectory()
    let directory = MMKVDirectory(path: rootDirectory)
    #expect(!directory.containsStore(id: "store"))
    #expect(!directory.containsStore())

    let store = try makeStore(id: "store", rootDirectory: rootDirectory)
    store.set(1.0, forKey: "key")
    #expect(directory.containsStore(id: "store"))
    #expect(!directory.containsStore(id: "other"))
  }

  @Test func `Checking For A Store Creates Nothing`() {
    let rootDirectory = temporaryRootDirectory() + "/missing"
    let directory = MMKVDirectory(path: rootDirectory)
    #expect(!directory.containsStore(id: "store"))
    #expect(!FileManager.default.fileExists(atPath: rootDirectory))
    #expect(!MMKVDirectory(path: "").containsStore(id: "store"))
    #expect(!directory.containsStore(id: ""))
  }

  @Test func `Removes The Files Of A Store That Is Not Open`() throws {
    let rootDirectory = temporaryRootDirectory()
    let directory = MMKVDirectory(path: rootDirectory)
    try self.makeUnopenedStore(id: "store", in: rootDirectory)
    #expect(directory.containsStore(id: "store"))

    #expect(try directory.removeStore(id: "store"))
    #expect(!directory.containsStore(id: "store"))
    #expect(!FileManager.default.fileExists(atPath: "\(rootDirectory)/store"))
    #expect(!FileManager.default.fileExists(atPath: "\(rootDirectory)/store.crc"))

    let reopened = try makeStore(id: "store", rootDirectory: rootDirectory)
    #expect(reopened.keys.isEmpty)
  }

  @Test func `Removing A Store With No Files Reports That Nothing Was Removed`() throws {
    let directory = MMKVDirectory(path: temporaryRootDirectory())
    #expect(try !directory.removeStore(id: "store"))
    #expect(try !MMKVDirectory(path: temporaryRootDirectory() + "/missing").removeStore())
  }

  @Test func `Refuses To Remove A Store That Is Open`() throws {
    let rootDirectory = temporaryRootDirectory()
    let directory = MMKVDirectory(path: rootDirectory)
    let store = try makeStore(id: "store", rootDirectory: rootDirectory)
    store.set("value", forKey: "key")

    #expect(throws: MMKVError.storeIsOpen(id: "store", directory: directory)) {
      try directory.removeStore(id: "store")
    }
    // The same directory spelled differently is still the same store.
    let respelled = MMKVDirectory(path: rootDirectory + "/")
    #expect(throws: MMKVError.storeIsOpen(id: "store", directory: respelled)) {
      try respelled.removeStore(id: "store")
    }
    #expect(directory.containsStore(id: "store"))
    #expect(store["key", as: String.self] == "value")
  }
}
