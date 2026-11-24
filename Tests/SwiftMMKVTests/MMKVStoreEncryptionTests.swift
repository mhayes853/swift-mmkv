import Foundation
import SwiftMMKV
import Testing

@Suite(.requires(.store, .encryption)) struct MMKVStoreEncryptionTests {
  private static let secret = "a very recognisable plaintext value"

  private func fileContainsSecret(rootDirectory: String, id: String) throws -> Bool {
    let contents = try Data(contentsOf: URL(fileURLWithPath: "\(rootDirectory)/\(id)"))
    return contents.range(of: Data(Self.secret.utf8)) != nil
  }

  @Test(arguments: [
    MMKVConfiguration.Encryption.aes128(key: "0123456789abcdef"),
    .aes256(key: "0123456789abcdef0123456789abcdef"),
    .aes128(key: "short")
  ])
  func `Encrypted Stores Round Trip Without Plaintext On Disk`(
    encryption: MMKVConfiguration.Encryption
  ) throws {
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(id: "secret", rootDirectory: rootDirectory, encryption: encryption)

    store.set(Self.secret, forKey: "key")
    store.set(42.0, forKey: "number")
    store.sync()

    #expect(store.value(forKey: "key", as: String.self) == Self.secret)
    #expect(store.value(forKey: "number", as: Double.self) == 42)
    #expect(try !self.fileContainsSecret(rootDirectory: rootDirectory, id: "secret"))
  }

  @Test func `A Plain Store Has Plaintext On Disk`() throws {
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(id: "plain", rootDirectory: rootDirectory)

    store.set(Self.secret, forKey: "key")
    store.sync()

    #expect(try self.fileContainsSecret(rootDirectory: rootDirectory, id: "plain"))
  }

  @Test func `Rekeying Encrypts Decrypts And Updates The Configuration`() throws {
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(id: "rekey", rootDirectory: rootDirectory)
    store.set(Self.secret, forKey: "key")

    try store.rekey(.aes256(key: "a new key"))
    store.sync()
    #expect(store.value(forKey: "key", as: String.self) == Self.secret)
    #expect(try !self.fileContainsSecret(rootDirectory: rootDirectory, id: "rekey"))
    #expect(store.configuration.encryption == .aes256(key: "a new key"))

    try store.rekey(nil)
    store.sync()
    #expect(store.value(forKey: "key", as: String.self) == Self.secret)
    #expect(try self.fileContainsSecret(rootDirectory: rootDirectory, id: "rekey"))
    #expect(store.configuration.encryption == nil)
  }

  @Test(arguments: [
    MMKVConfiguration.Encryption.aes128(key: [UInt8]()),
    .aes128(key: [UInt8](repeating: 1, count: 17)),
    .aes256(key: [UInt8]()),
    .aes256(key: [UInt8](repeating: 1, count: 33))
  ])
  func `Rejects Keys Of The Wrong Length`(encryption: MMKVConfiguration.Encryption) throws {
    expectError(.invalidEncryptionKey) {
      try makeStore(encryption: encryption)
    }
    let store = try makeStore()
    expectError(.invalidEncryptionKey) {
      try store.rekey(encryption)
    }
  }

  // MMKV keeps a store open for the rest of the process, so each of these opens a copy of an
  // encrypted store's files, as a later launch of the app would.

  @Test(
    .requires(.encryptionKeyCheck),
    arguments: [
      MMKVConfiguration.Encryption.aes128(key: "another key"),
      .aes256(key: "the right key")
    ]
  )
  func `Opening With The Wrong Key Throws And Leaves The Store As It Was`(
    wrong: MMKVConfiguration.Encryption
  ) throws {
    let (rootDirectory, id) = try self.makeUnopenedEncryptedStore()
    let files = try self.storeFiles(rootDirectory: rootDirectory, id: id)

    expectError(.wrongEncryptionKey) {
      try makeStore(id: id, rootDirectory: rootDirectory, encryption: wrong)
    }
    #expect(try self.storeFiles(rootDirectory: rootDirectory, id: id) == files)

    let store = try makeStore(
      id: id,
      rootDirectory: rootDirectory,
      encryption: .aes128(key: "the right key")
    )
    #expect(store.value(forKey: "key", as: String.self) == Self.secret)
  }

  @Test(.requires(.encryptionKeyCheck))
  func `A Store Whose Key Is Lost Can Be Removed And Started Again`() throws {
    let (rootDirectory, id) = try self.makeUnopenedEncryptedStore()
    let lost = MMKVConfiguration.Encryption.aes128(key: "a new key")
    #expect(throws: MMKVError.self) {
      try makeStore(id: id, rootDirectory: rootDirectory, encryption: lost)
    }

    #expect(try MMKVDirectory(path: rootDirectory).removeStore(id: id))
    let store = try makeStore(id: id, rootDirectory: rootDirectory, encryption: lost)
    #expect(store.count == 0)
    store.set("fresh", forKey: "key")
    #expect(store.value(forKey: "key", as: String.self) == "fresh")
  }

  @Test(.requires(.encryptionKeyCheck))
  func `An Encrypted Store Opened Without Its Key Refuses Writes`() throws {
    let (rootDirectory, id) = try self.makeUnopenedEncryptedStore()
    let files = try self.storeFiles(rootDirectory: rootDirectory, id: id)

    // A store with no key loads its file when it is first used.
    let store = try makeStore(id: id, rootDirectory: rootDirectory)
    #expect(store.count == 0)
    #expect(!store.set("value", forKey: "other"))
    store.trim()
    expectError(.rekeyFailed) {
      try store.rekey(.aes128(key: "another key"))
    }
    store.sync()
    #expect(try self.storeFiles(rootDirectory: rootDirectory, id: id) == files)
    #expect(throws: MMKVError.self) { try makeStore(id: id, rootDirectory: rootDirectory) }

    store.removeAll()
    store.set("fresh", forKey: "key")
    #expect(store.value(forKey: "key", as: String.self) == "fresh")
  }

  /// The files of a store encrypted with "the right key" that this process has not opened.
  private func makeUnopenedEncryptedStore() throws -> (rootDirectory: String, id: MMKVStore.ID) {
    let rootDirectory = temporaryRootDirectory()
    let source = try makeStore(
      id: "source",
      rootDirectory: rootDirectory,
      encryption: .aes128(key: "the right key")
    )
    source.set(Self.secret, forKey: "key")
    source.set(42.0, forKey: "number")
    source.sync()
    try copyStoreFiles(id: "source", to: "copy", in: rootDirectory)
    return (rootDirectory, "copy")
  }

  private func storeFiles(rootDirectory: String, id: MMKVStore.ID) throws -> [Data] {
    try ["", ".crc"]
      .map { try Data(contentsOf: URL(fileURLWithPath: "\(rootDirectory)/\(id)\($0)")) }
  }
}
