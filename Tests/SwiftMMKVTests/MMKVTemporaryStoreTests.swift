import Foundation
import SwiftMMKV
import Testing

@Suite struct MMKVTemporaryStoreTests {
  @Test func `A Temporary Directory Is A New One Inside The System's On Every Call`() {
    let first = MMKVDirectory.temporary()
    let second = MMKVDirectory.temporary()

    #expect(first != second)
    #expect(first.path.hasPrefix(NSTemporaryDirectory()))
    #expect(second.path.hasPrefix(NSTemporaryDirectory()))
  }

  @Test func `A Temporary Directory Is Not Created Until A Store Is Opened In It`() throws {
    let directory = MMKVDirectory.temporary()
    #expect(!FileManager.default.fileExists(atPath: directory.path))

    _ = try MMKVStore(MMKVConfiguration(directory: directory, mode: .singleProcess))

    #expect(FileManager.default.fileExists(atPath: directory.path))
    #expect(directory.containsStore())
  }

  @Test func `A Temporary Configuration Is Single Process In A Temporary Directory`() {
    let configuration = MMKVConfiguration.temporary()
    let named = MMKVConfiguration.temporary(id: "settings")

    #expect(configuration.id == .default)
    #expect(configuration.mode == .singleProcess)
    #expect(configuration.directory.path.hasPrefix(NSTemporaryDirectory()))
    #expect(named.id == "settings")
    #expect(named.directory != configuration.directory)
  }

  @Test func `Temporary Stores Start Empty And Do Not Share Values`() throws {
    let first = try MMKVStore(.temporary())
    let second = try MMKVStore(.temporary())

    first.set("blob", forKey: "username")

    #expect(first.value(forKey: "username", as: String.self) == "blob")
    #expect(second.keys.isEmpty)
  }

  @Test func `A Temporary Configuration Can Be Changed Like Any Other`() throws {
    var configuration = MMKVConfiguration.temporary()
    configuration.itemSizeLimit = 16
    let store = try MMKVStore(configuration)

    #expect(store.set("small", forKey: "key"))
    #expect(!store.set(String(repeating: "x", count: 64), forKey: "large"))
  }
}
