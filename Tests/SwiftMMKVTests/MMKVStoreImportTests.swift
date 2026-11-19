import SwiftMMKV
import Testing

@Suite(.requires(.store, .importing)) struct MMKVStoreImportTests {
  @Test func `Copies Every Key And Replaces Those That Exist`() throws {
    let source = try makeStore()
    source.set("new", forKey: "shared")
    source.set(2.0, forKey: "number")
    source.set([1, 2, 3] as [UInt8], forKey: "bytes")
    let destination = try makeStore()
    destination.set("old", forKey: "shared")
    destination.set(true, forKey: "kept")

    #expect(destination.importAll(from: source) == 3)

    #expect(destination.keys == ["shared", "number", "bytes", "kept"])
    #expect(destination["shared", as: String.self] == "new")
    #expect(destination["number", as: Double.self] == 2)
    #expect(destination["bytes", as: [UInt8].self] == [1, 2, 3])
    #expect(destination["kept", as: Bool.self] == true)
    #expect(source.keys == ["shared", "number", "bytes"])
  }

  @Test(.requires(.encryption)) func `Copies Between Stores With Different Encryption`() throws {
    let source = try makeStore(encryption: .aes256(key: "source-key"))
    source.set("secret", forKey: "token")
    let plain = try makeStore()
    let encrypted = try makeStore(encryption: .aes128(key: "other-key"))

    #expect(plain.importAll(from: source) == 1)
    #expect(encrypted.importAll(from: plain) == 1)
    #expect(plain["token", as: String.self] == "secret")
    #expect(encrypted["token", as: String.self] == "secret")
  }

  @Test func `Copies Nothing From An Empty Store Or Itself`() throws {
    let rootDirectory = temporaryRootDirectory()
    let store = try makeStore(rootDirectory: rootDirectory)
    store.set("value", forKey: "key")
    let sameFiles = try makeStore(rootDirectory: rootDirectory)

    #expect(store.importAll(from: try makeStore()) == 0)
    #expect(store.importAll(from: store) == 0)
    #expect(store.importAll(from: sameFiles) == 0)
    #expect(store.keys == ["key"])
  }

  @Test(.requires(.readOnly)) func `Copies Nothing Into A Read Only Store`() throws {
    let rootDirectory = temporaryRootDirectory()
    try makeUnopenedStoreFiles(at: "\(rootDirectory)/readonly")
    let readOnly = try makeStore(id: "readonly", rootDirectory: rootDirectory, isReadOnly: true)
    let source = try makeStore()
    source.set("other", forKey: "other")

    #expect(readOnly.importAll(from: source) == 0)
    #expect(readOnly.keys == ["key"])
  }

  @Test func `Reports Each Imported Key To Listeners`() throws {
    let source = try makeStore()
    source.set("a", forKey: "a")
    source.set("b", forKey: "b")
    let destination = try makeStore()
    destination.set("c", forKey: "c")
    let recorder = ChangeRecorder()
    let subscription = destination.subscribe(recorder.record)
    let values = ValueRecorder<String?>()
    let keySubscription = destination.subscribe(forKey: "a", as: String.self, values.record)

    destination.importAll(from: source)
    #expect(Set(recorder.all) == [.key("a"), .key("b")])
    #expect(recorder.all.count == 2)
    #expect(values.all == [nil, "a"])

    destination.importAll(from: try makeStore())
    #expect(recorder.all.count == 2)
    subscription.cancel()
    keySubscription.cancel()
  }
}
