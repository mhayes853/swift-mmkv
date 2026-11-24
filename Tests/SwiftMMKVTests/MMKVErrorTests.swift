import Foundation
import SwiftMMKV
import Testing

@Suite struct MMKVErrorTests {
  @Test func `An Error Has A Code And A Message`() {
    let error = MMKVError(code: .storeIsOpen, message: "The store is open.")

    #expect(error.code == .storeIsOpen)
    #expect(error.code.rawValue == "store-is-open")
    #expect(error.message == "The store is open.")
    #expect(error.description == "The store is open.")
    #expect(error == MMKVError(code: .storeIsOpen, message: "The store is open."))
    #expect(error != MMKVError(code: .storeIsSuspended, message: "The store is open."))
  }

  @Test func `A Code This Version Does Not Have Is Still A Code`() {
    let code = MMKVError.Code(rawValue: "from-a-later-version")

    #expect(code != .storeIsOpen)
    #expect(MMKVError(code: code, message: "").code.rawValue == "from-a-later-version")
  }

  @Test func `Codes Are Distinct`() {
    let codes: [MMKVError.Code] = [
      .openFailed, .invalidEncryptionKey, .rekeyFailed, .disableExpiryFailed,
      .appGroupContainerUnavailable, .writeFailed, .storeIsOpen, .storesAreOpen,
      .directoryUnreadable, .backupFailed, .restoreFailed, .storesNotBackedUp,
      .storesNotRestored, .backupInvalid, .backupIsStoreDirectory, .storeIsSuspended,
      .storeIsClosed
    ]
    #expect(Set(codes).count == codes.count)
    #expect(Set(codes.map(\.rawValue)).count == codes.count)
  }

  @Test func `A Thrown Error Is Caught By Its Code`() throws {
    let rootDirectory = temporaryRootDirectory()
    let directory = MMKVDirectory(path: rootDirectory)
    let store = try makeStore(id: "settings", rootDirectory: rootDirectory)
    store.set("dark", forKey: "theme")

    // A function, and not a variable that the `catch` sets: the Swift 6.3.3 compiler crashes
    // while compiling this test written that way.
    func removing() -> MMKVError? {
      do {
        try directory.removeStore(id: "settings")
        return nil
      } catch  where error.code == .storeIsOpen {
        return error
      } catch {
        return nil
      }
    }

    let error = try #require(removing())
    #expect(
      error.message == "The store \"settings\" in \"\(rootDirectory)\" is open in this process."
    )
  }

  @Test func `A Thrown Error's Message Names What It Is About`() throws {
    let store = try makeStore(id: "settings", mode: .multiProcess)
    store.suspend()

    let error = expectError(.storeIsSuspended) {
      try store.rekey(.aes128(key: "secret"))
    }

    #expect(error?.message == "The store \"settings\" is suspended.")
    #expect(error.map { "\($0)" } == "The store \"settings\" is suspended.")
  }

  #if Foundation
    @Test func `An Error's Localized Description Is Its Message`() {
      let error: any Error = MMKVError(code: .rekeyFailed, message: "The store is read-only.")

      #expect(error.localizedDescription == "The store is read-only.")
    }
  #endif
}
