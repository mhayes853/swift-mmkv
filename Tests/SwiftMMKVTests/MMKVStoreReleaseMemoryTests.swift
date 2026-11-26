import Foundation
import SwiftMMKV
import Testing

@Suite struct MMKVStoreReleaseMemoryTests {
  @Test func `Keeps Every Value`() throws {
    let store = try makeStore()
    store.set("blob", forKey: "username")
    store.set(0.5, forKey: "volume")
    store.set(["a", "b"], forKey: "tags")

    store.releaseMemory()

    #expect(store.value(forKey: "username", as: String.self) == "blob")
    #expect(store.value(forKey: "volume", as: Double.self) == 0.5)
    #expect(store.value(forKey: "tags", as: [String].self) == ["a", "b"])
    #expect(store.keys == ["username", "volume", "tags"])
    #expect(store.count == 3)
  }

  @Test func `Writes Afterwards Are Kept`() throws {
    let store = try makeStore()
    store.set("blob", forKey: "username")

    store.releaseMemory()
    #expect(store.set("blob jr", forKey: "username"))
    #expect(store.set(1.0, forKey: "volume"))
    store.releaseMemory()

    #expect(store.value(forKey: "username", as: String.self) == "blob jr")
    #expect(store.value(forKey: "volume", as: Double.self) == 1.0)
  }

  @Test func `Can Be Repeated And Called On An Empty Store`() throws {
    let store = try makeStore()

    store.releaseMemory()
    store.releaseMemory()

    #expect(store.keys.isEmpty)
    #expect(store.set(1.0, forKey: "volume"))
    #expect(store.value(forKey: "volume", as: Double.self) == 1.0)
  }

  @Test func `Tells Listeners Nothing`() throws {
    let store = try makeStore()
    store.set("blob", forKey: "username")
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)

    store.releaseMemory()
    #expect(store.value(forKey: "username", as: String.self) == "blob")
    store.checkForExternalChanges()

    #expect(recorder.all.isEmpty)
    subscription.cancel()
  }

  @Test func `Keeps The Values Of An Encrypted Store`() throws {
    let store = try makeStore(encryption: .aes256(key: "secret"))
    store.set("blob", forKey: "username")

    store.releaseMemory()

    #expect(store.value(forKey: "username", as: String.self) == "blob")
    #expect(store.set("blob jr", forKey: "username"))
    #expect(store.value(forKey: "username", as: String.self) == "blob jr")
  }

  @Test func `Keeps The Values Of A Multi Process Store`() throws {
    let store = try makeStore(id: "release-memory-multi-process", mode: .multiProcess)
    store.set("blob", forKey: "username")
    let recorder = ChangeRecorder()
    let subscription = store.subscribe(recorder.record)

    store.releaseMemory()

    #expect(store.value(forKey: "username", as: String.self) == "blob")
    #expect(recorder.all.isEmpty)
    subscription.cancel()
  }

  @Test func `Every Store Over The Same Files Keeps Its Values`() throws {
    let rootDirectory = temporaryRootDirectory()
    let first = try makeStore(rootDirectory: rootDirectory)
    let second = try makeStore(rootDirectory: rootDirectory)
    first.set("blob", forKey: "username")

    first.releaseMemory()

    #expect(second.value(forKey: "username", as: String.self) == "blob")
    #expect(second.set("blob jr", forKey: "username"))
    #expect(first.value(forKey: "username", as: String.self) == "blob jr")
  }

  @Test func `Does Nothing To A Suspended Store`() throws {
    let store = try makeStore(id: "release-memory-suspended", mode: .multiProcess)
    store.set("blob", forKey: "username")
    store.suspend()

    store.releaseMemory()

    store.resume()
    #expect(store.value(forKey: "username", as: String.self) == "blob")
  }

  @Test func `Keeps Values Larger Than The Initial File`() throws {
    let store = try makeStore()
    let large = String(repeating: "x", count: 512 * 1024)
    store.set(large, forKey: "large")
    let byteSize = store.byteSize

    store.releaseMemory()

    #expect(store.value(forKey: "large", as: String.self) == large)
    #expect(store.byteSize == byteSize)
  }
}
