import Foundation
import SwiftMMKV
import Testing

extension MMKVStore.ID {
  fileprivate static let settings: Self = "settings"

  fileprivate static func user(_ userID: Int) -> Self {
    "user.\(userID)"
  }
}

@Suite struct MMKVStoreIDTests {
  @Test func `The Default Is The One React Native MMKV Uses`() {
    #expect(MMKVStore.ID.default.rawValue == "mmkv.default")
    let configuration = MMKVConfiguration(
      directory: MMKVDirectory(path: "/tmp"),
      mode: .singleProcess
    )
    #expect(configuration.id == .default)
  }

  @Test func `Is Made From A Literal An Interpolation Or A Raw Value`() {
    #expect(MMKVStore.ID.settings == MMKVStore.ID(rawValue: "settings"))
    #expect(MMKVStore.ID.user(42).rawValue == "user.42")
    #expect("\(MMKVStore.ID.user(42))" == "user.42")
  }

  @Test func `Sorts By Its Raw Value`() {
    let ids: [MMKVStore.ID] = ["b", .settings, "a"]

    #expect(ids.sorted() == ["a", "b", "settings"])
  }

  @Test func `Encodes As A Plain String`() throws {
    let data = try JSONEncoder().encode([MMKVStore.ID.settings])

    #expect(String(decoding: data, as: UTF8.self) == #"["settings"]"#)
    #expect(try JSONDecoder().decode([MMKVStore.ID].self, from: data) == [.settings])
  }

  @Test func `Names The Store It Opens And Its Files`() throws {
    let rootDirectory = temporaryRootDirectory()
    let directory = MMKVDirectory(path: rootDirectory)

    let store = try makeStore(id: .user(7), rootDirectory: rootDirectory)

    #expect(store.id == .user(7))
    #expect(directory.containsStore(id: .user(7)))
    #expect(!directory.containsStore(id: .settings))
    #expect(try directory.stores.map(\.id) == [.user(7)])
    #expect(throws: MMKVError.storeIsOpen(id: .user(7), directory: directory)) {
      try directory.removeStore(id: .user(7))
    }
  }
}
