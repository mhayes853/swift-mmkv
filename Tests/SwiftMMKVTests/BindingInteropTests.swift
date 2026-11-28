import Foundation
import SwiftMMKV
import Testing

/// Stores that this package and a binding in another language read from each other, which
/// `BINDINGS.md` asks every binding to test.
///
/// Both tests are skipped unless `SWIFTMMKV_INTEROP_DIRECTORY` names a directory. A binding's
/// CI job runs this suite once to write the stores `written-by-swift` and
/// `written-by-swift-encrypted` there. Its own tests then read them, and write the same
/// values to stores of their own. The job names those in `SWIFTMMKV_INTEROP_BINDING_STORES`,
/// separated by commas, and runs this suite again to read them back.
///
/// The values are the same in every language: see `interopValues` here, and
/// `python/tests/test_interop.py`. Each store has a twin whose identifier ends in
/// `-encrypted`, with AES-256 and the key `interop-secret`.
@Suite struct BindingInteropTests {
  private static let environment = ProcessInfo.processInfo.environment
  static let directory = environment["SWIFTMMKV_INTEROP_DIRECTORY"]
  static let bindingStores = (environment["SWIFTMMKV_INTEROP_BINDING_STORES"] ?? "")
    .split(separator: ",")
    .map(String.init)

  private static let encryptionKey = "interop-secret"

  private static func open(id: String, isEncrypted: Bool) throws -> MMKVStore {
    try MMKVStore(
      MMKVConfiguration(
        id: MMKVStore.ID(rawValue: isEncrypted ? id + "-encrypted" : id),
        directory: MMKVDirectory(path: try #require(Self.directory)),
        mode: .singleProcess,
        encryption: isEncrypted ? .aes256(key: Self.encryptionKey) : nil
      )
    )
  }

  @Test(.enabled(if: directory != nil), arguments: [false, true])
  func `Writes A Store For Bindings To Read`(isEncrypted: Bool) throws {
    let store = try Self.open(id: "written-by-swift", isEncrypted: isEncrypted)
    defer { store.close() }
    store.removeAll()

    #expect(store.set(true, forKey: "bool"))
    #expect(store.set(Int32.min, forKey: "int32"))
    #expect(store.set(UInt32.max, forKey: "uint32"))
    #expect(store.set(Int64.min, forKey: "int64"))
    #expect(store.set(UInt64.max, forKey: "uint64"))
    #expect(store.set(Float(1.5), forKey: "float"))
    #expect(store.set(Double.pi, forKey: "double"))
    #expect(store.set("blob ✓ 日本語", forKey: "string"))
    #expect(store.set("", forKey: "empty"))
    #expect(store.set([UInt8]([0, 1, 2, 254, 255]), forKey: "bytes"))
    #expect(store.set(["a", "", "ç"], forKey: "strings"))
    #expect(store.set(Int.MMKVNumber(42), forKey: "number"))

    #expect(store.count == 12)
  }

  @Test(
    .enabled(if: directory != nil && !bindingStores.isEmpty),
    arguments: bindingStores,
    [false, true]
  )
  func `Reads The Store A Binding Wrote`(id: String, isEncrypted: Bool) throws {
    let store = try Self.open(id: id, isEncrypted: isEncrypted)
    defer { store.close() }

    #expect(store.value(forKey: "bool", as: Bool.self) == true)
    #expect(store.value(forKey: "int32", as: Int32.self) == Int32.min)
    #expect(store.value(forKey: "uint32", as: UInt32.self) == UInt32.max)
    #expect(store.value(forKey: "int64", as: Int64.self) == Int64.min)
    #expect(store.value(forKey: "uint64", as: UInt64.self) == UInt64.max)
    #expect(store.value(forKey: "float", as: Float.self) == 1.5)
    #expect(store.value(forKey: "double", as: Double.self) == Double.pi)
    #expect(store.value(forKey: "string", as: String.self) == "blob ✓ 日本語")
    #expect(store.value(forKey: "empty", as: String.self) == "")
    #expect(store.value(forKey: "bytes", as: [UInt8].self) == [0, 1, 2, 254, 255])
    #expect(store.value(forKey: "strings", as: [String].self) == ["a", "", "ç"])
    #expect(store.value(forKey: "number", as: Int.MMKVNumber.self) == 42)
    #expect(store.count == 12)
  }
}
