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
    try makeUnopenedStoreFiles(at: "\(rootDirectory)/\(id)")
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
    #expect(try !MMKVDirectory(path: "").removeStore())
    #expect(try !directory.removeStore(id: ""))
    #expect(try MMKVDirectory(path: "").stores.isEmpty)
  }

  @Test func `Refuses To Remove A Store That Is Open`() throws {
    let rootDirectory = temporaryRootDirectory()
    let directory = MMKVDirectory(path: rootDirectory)
    let store = try makeStore(id: "store", rootDirectory: rootDirectory)
    store.set("value", forKey: "key")

    expectError(.storeIsOpen) {
      try directory.removeStore(id: "store")
    }
    // The same directory spelled differently is still the same store.
    let respelled = MMKVDirectory(path: rootDirectory + "/")
    expectError(.storeIsOpen) {
      try respelled.removeStore(id: "store")
    }
    #expect(directory.containsStore(id: "store"))
    #expect(store["key", as: String.self] == "value")
  }

  @Test func `Refuses To Remove An Open Store Reached Through A Symbolic Link`() throws {
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(id: "store", rootDirectory: rootDirectory)
    store.set("value", forKey: "key")
    let linkPath = temporaryRootDirectory() + "/link"
    try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: rootDirectory)
    let linked = MMKVDirectory(path: linkPath)

    expectError(.storeIsOpen) {
      try linked.removeStore(id: "store")
    }
    expectError(.storesAreOpen) {
      try linked.removeAllStores()
    }
    #expect(store["key", as: String.self] == "value")
  }
}

@Suite struct MMKVDirectoryListingTests {
  @Test func `Lists The Stores That Have Files`() throws {
    let rootDirectory = temporaryRootDirectory()
    let directory = MMKVDirectory(path: rootDirectory)
    #expect(try directory.stores.isEmpty)

    try makeStore(id: "b", rootDirectory: rootDirectory).set(1.0, forKey: "key")
    try makeStore(id: "a", rootDirectory: rootDirectory).set(1.0, forKey: "key")
    try Data().write(to: URL(fileURLWithPath: "\(rootDirectory)/not-a-store"))
    try FileManager.default.createDirectory(
      atPath: "\(rootDirectory)/folder",
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      atPath: "\(rootDirectory)/folder.crc",
      withIntermediateDirectories: true
    )

    let stores = try directory.stores
    #expect(stores.map(\.id) == ["a", "b"])
    #expect(stores.map(\.relativePath) == ["a", "b"])
    #expect(stores[0].isStore(id: "a"))
    #expect(!stores[0].isStore(id: "b"))
  }

  @Test func `A Directory That Does Not Exist Has No Stores`() throws {
    let directory = MMKVDirectory(path: temporaryRootDirectory() + "/missing")
    #expect(try directory.stores.isEmpty)
    #expect(try directory.removeAllStores() == 0)
  }

  @Test func `A Path That Is Not A Directory Cannot Be Listed`() throws {
    let path = temporaryRootDirectory() + "/file"
    try Data().write(to: URL(fileURLWithPath: path))
    let directory = MMKVDirectory(path: path)
    expectError(.directoryUnreadable) { try directory.stores }
    expectError(.directoryUnreadable) { try directory.removeAllStores() }
  }

  @Test func `Lists A Store Whose Identifier Is Hashed Without Its Identifier`() throws {
    let rootDirectory = temporaryRootDirectory()
    let directory = MMKVDirectory(path: rootDirectory)
    let store = try makeStore(id: "user/42", rootDirectory: rootDirectory)
    store.set("value", forKey: "key")

    let stores = try directory.stores
    #expect(stores.count == 1)
    #expect(stores[0].id == nil)
    #expect(stores[0].relativePath.hasPrefix("specialCharacter/"))
    #expect(stores[0].isStore(id: "user/42"))
    #expect(!stores[0].isStore(id: "user/43"))
    #expect(FileManager.default.fileExists(atPath: "\(rootDirectory)/\(stores[0].relativePath)"))
    #expect(directory.containsStore(id: "user/42"))

    expectError(.storeIsOpen) {
      try directory.removeStore(stores[0])
    }
    expectError(.storeIsOpen) {
      try directory.removeStore(id: "user/42")
    }
    #expect(store["key", as: String.self] == "value")
  }

  @Test func `Removes A Listed Store`() throws {
    let rootDirectory = temporaryRootDirectory()
    let directory = MMKVDirectory(path: rootDirectory)
    try makeUnopenedStoreFiles(at: "\(rootDirectory)/named")
    try makeUnopenedStoreFiles(at: "\(rootDirectory)/specialCharacter/0123456789abcdef")

    let stores = try directory.stores
    #expect(stores.map(\.id) == ["named", nil])
    for store in stores {
      #expect(try directory.removeStore(store))
      #expect(try !directory.removeStore(store))
    }
    #expect(try directory.stores.isEmpty)
    #expect(
      !FileManager.default.fileExists(
        atPath: "\(rootDirectory)/specialCharacter/0123456789abcdef.crc"
      )
    )
  }

  @Test func `Removing Every Store Leaves The Open Ones And Reports Them`() throws {
    let rootDirectory = temporaryRootDirectory()
    let directory = MMKVDirectory(path: rootDirectory)
    try makeUnopenedStoreFiles(at: "\(rootDirectory)/closed")
    try makeUnopenedStoreFiles(at: "\(rootDirectory)/specialCharacter/0123456789abcdef")
    let open = try makeStore(id: "open", rootDirectory: rootDirectory)
    open.set("value", forKey: "key")
    let hashed = try makeStore(id: "open:hashed", rootDirectory: rootDirectory)
    hashed.set("value", forKey: "key")

    let error = expectError(.storesAreOpen) {
      try directory.removeAllStores()
    }
    // A store whose files do not tell its identifier is named by the one it was opened with.
    #expect(error?.message.contains("\"open\", \"open:hashed\"") == true)
    #expect(error?.message.contains(rootDirectory) == true)
    #expect(try directory.stores.count == 2)
    #expect(directory.containsStore(id: "open"))
    #expect(directory.containsStore(id: "open:hashed"))
    #expect(!directory.containsStore(id: "closed"))
    #expect(open["key", as: String.self] == "value")
    #expect(hashed["key", as: String.self] == "value")
  }

  @Test func `Removes Every Store When None Is Open`() throws {
    let rootDirectory = temporaryRootDirectory()
    let directory = MMKVDirectory(path: rootDirectory)
    for name in ["a", "b", "specialCharacter/0123456789abcdef"] {
      try makeUnopenedStoreFiles(at: "\(rootDirectory)/\(name)")
    }
    #expect(try directory.removeAllStores() == 3)
    #expect(try directory.stores.isEmpty)
  }
}
