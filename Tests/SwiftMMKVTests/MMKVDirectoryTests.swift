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
