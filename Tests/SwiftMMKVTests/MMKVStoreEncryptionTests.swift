import Foundation
import SwiftMMKV
import Testing

@Suite struct MMKVStoreEncryptionTests {
  private static let secret = "a very recognisable plaintext value"

  private func fileContains(_ text: String, rootDirectory: String, id: String) throws -> Bool {
    let contents = try Data(contentsOf: URL(fileURLWithPath: "\(rootDirectory)/\(id)"))
    return contents.range(of: Data(text.utf8)) != nil
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
    #expect(try !self.fileContains(Self.secret, rootDirectory: rootDirectory, id: "secret"))
  }

  @Test func `A Plain Store Has Plaintext On Disk`() throws {
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(id: "plain", rootDirectory: rootDirectory)

    store.set(Self.secret, forKey: "key")
    store.sync()

    #expect(try self.fileContains(Self.secret, rootDirectory: rootDirectory, id: "plain"))
  }

  @Test func `Rekeying Encrypts Decrypts And Updates The Configuration`() throws {
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(id: "rekey", rootDirectory: rootDirectory)
    store.set(Self.secret, forKey: "key")

    try store.rekey(.aes256(key: "a new key"))
    store.sync()
    #expect(store.value(forKey: "key", as: String.self) == Self.secret)
    #expect(try !self.fileContains(Self.secret, rootDirectory: rootDirectory, id: "rekey"))
    #expect(store.configuration.encryption == .aes256(key: "a new key"))

    try store.rekey(nil)
    store.sync()
    #expect(store.value(forKey: "key", as: String.self) == Self.secret)
    #expect(try self.fileContains(Self.secret, rootDirectory: rootDirectory, id: "rekey"))
    #expect(store.configuration.encryption == nil)
  }

  @Test(arguments: [
    MMKVConfiguration.Encryption.aes128(key: [UInt8]()),
    .aes128(key: [UInt8](repeating: 1, count: 17)),
    .aes256(key: [UInt8]()),
    .aes256(key: [UInt8](repeating: 1, count: 33))
  ])
  func `Rejects Keys Of The Wrong Length`(encryption: MMKVConfiguration.Encryption) throws {
    #expect(throws: MMKVError.invalidEncryptionKey) {
      try makeStore(encryption: encryption)
    }
    let store = try makeStore()
    #expect(throws: MMKVError.invalidEncryptionKey) {
      try store.rekey(encryption)
    }
  }
}
