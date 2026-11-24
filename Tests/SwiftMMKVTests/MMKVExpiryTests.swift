import Foundation
import SwiftMMKV
import Testing

extension MMKVStore.Key where Value == String {
  fileprivate static let token: Self = "token"
}

extension MMKVStore.CodedKey where Value == Int {
  fileprivate static let attempts = Self(
    "attempts",
    encoder: TextCoder.shared,
    decoder: TextCoder.shared
  )
}

private struct Session: Codable, Equatable {
  var user: String
  var isAdmin: Bool
}

@Suite struct MMKVExpiryTests {
  /// Longer than the second an expiry is rounded up to, and the second the core's clock may
  /// be behind by.
  private static let expiredAfter = Duration.seconds(2.1)

  private func makeStore(
    rootDirectory: String = temporaryRootDirectory(),
    mode: MMKVConfiguration.Mode = .singleProcess,
    isReadOnly: Bool = false,
    defaultExpiry: MMKVExpiry? = nil
  ) throws -> MMKVStore {
    var configuration = MMKVConfiguration(
      id: "cache",
      directory: MMKVDirectory(path: rootDirectory),
      mode: mode,
      isReadOnly: isReadOnly
    )
    if let defaultExpiry {
      configuration.defaultExpiry = defaultExpiry
    }
    return try MMKVStore(configuration)
  }

  private var now: Int64 {
    Int64(Date().timeIntervalSince1970)
  }

  // MARK: - Expiries

  @Test func `Expiries Compare By What They Say`() {
    #expect(MMKVExpiry.never == .never)
    #expect(MMKVExpiry.after(.seconds(30)) == .after(.milliseconds(30_000)))
    #expect(MMKVExpiry.after(.seconds(30)) != .after(.seconds(31)))
    #expect(MMKVExpiry.at(secondsSince1970: 5) == .at(secondsSince1970: 5))
    #expect(MMKVExpiry.at(secondsSince1970: 5) != .never)
  }

  @Test func `A Value That Never Expires Leaves The File's Format Alone`() throws {
    let store = try self.makeStore()

    #expect(store.set("blob", forKey: "username", expiry: .never))
    #expect(store.set("blob", forKey: "name"))

    #expect(!store.isExpiryEnabled)
    #expect(store.value(forKey: "username", as: String.self) == "blob")
  }

  @Test func `A Value Expires After Its Duration`() async throws {
    let store = try self.makeStore()

    #expect(store.set("123456", forKey: "otp", expiry: .after(.seconds(1))))
    #expect(store.isExpiryEnabled)
    #expect(store.value(forKey: "otp", as: String.self) == "123456")

    try await Task.sleep(for: Self.expiredAfter)

    #expect(store.value(forKey: "otp", as: String.self) == nil)
    #expect(!store.contains("otp"))
    #expect(store.keys.isEmpty)
  }

  @Test func `A Duration Is Rounded Up And Is At Least A Second`() async throws {
    let store = try self.makeStore()

    store.set("a", forKey: "zero", expiry: .after(.zero))
    store.set("b", forKey: "negative", expiry: .after(.seconds(-60)))
    store.set("c", forKey: "fraction", expiry: .after(.milliseconds(3_600_001)))
    #expect(store.keys == ["zero", "negative", "fraction"])

    try await Task.sleep(for: Self.expiredAfter)

    #expect(store.keys == ["fraction"])
  }

  @Test func `A Value Expires At A Moment`() async throws {
    let store = try self.makeStore()

    store.set("soon", forKey: "soon", expiry: .at(secondsSince1970: self.now + 1))
    store.set("later", forKey: "later", expiry: .at(secondsSince1970: self.now + 3_600))
    #expect(store.keys == ["soon", "later"])

    try await Task.sleep(for: Self.expiredAfter)

    #expect(store.keys == ["later"])
  }

  @Test func `A Value Written After Its Moment Is Kept For A Second`() async throws {
    let store = try self.makeStore()

    #expect(store.set("old", forKey: "past", expiry: .at(secondsSince1970: self.now - 3_600)))
    #expect(store.set("older", forKey: "ancient", expiry: .at(secondsSince1970: .min)))
    #expect(store.keys == ["past", "ancient"])

    try await Task.sleep(for: Self.expiredAfter)

    #expect(store.keys.isEmpty)
  }

  @Test(
    arguments: [
      MMKVExpiry.after(.seconds(Int64.max)),
      .after(.seconds(Int64(UInt32.max))),
      .at(secondsSince1970: .max),
      .at(secondsSince1970: Int64(UInt32.max))
    ]
  )
  func `An Expiry Too Far Off To Record Is No Expiry`(expiry: MMKVExpiry) throws {
    let store = try self.makeStore()

    #expect(store.set("blob", forKey: "username", expiry: expiry))

    // The core would otherwise record the last moment it can, in 2106.
    #expect(!store.isExpiryEnabled)
    #expect(store.value(forKey: "username", as: String.self) == "blob")
  }

  @Test func `The Last Moment The Core Can Record Is An Expiry`() throws {
    let store = try self.makeStore()

    store.set("blob", forKey: "username", expiry: .at(secondsSince1970: Int64(UInt32.max) - 1))

    #expect(store.isExpiryEnabled)
    #expect(store.value(forKey: "username", as: String.self) == "blob")
  }

  @Test func `Overwriting A Value Replaces Its Expiry`() async throws {
    let store = try self.makeStore()
    store.set("a", forKey: "extended", expiry: .after(.seconds(1)))
    store.set("b", forKey: "kept", expiry: .after(.seconds(1)))
    store.set("c", forKey: "shortened", expiry: .never)

    store.set("a", forKey: "extended", expiry: .after(.seconds(3_600)))
    store.set("b", forKey: "kept", expiry: .never)
    store.set("c", forKey: "shortened", expiry: .after(.seconds(1)))
    try await Task.sleep(for: Self.expiredAfter)

    #expect(store.keys == ["extended", "kept"])
  }

  // MARK: - The Default

  @Test func `The Default Expiry Is Never`() {
    #expect(MMKVConfiguration.temporary().defaultExpiry == .never)
  }

  @Test func `A Write Without An Expiry Has The Store's Default`() async throws {
    let store = try self.makeStore(defaultExpiry: .after(.seconds(1)))
    #expect(store.configuration.defaultExpiry == .after(.seconds(1)))
    #expect(!store.isExpiryEnabled)

    store.set("a", forKey: "default")
    store.set("b", forKey: "never", expiry: .never)
    store.set("c", forKey: "longer", expiry: .after(.seconds(3_600)))
    #expect(store.isExpiryEnabled)
    #expect(store.keys == ["default", "never", "longer"])

    try await Task.sleep(for: Self.expiredAfter)

    #expect(store.keys == ["never", "longer"])
  }

  @Test func `Every Kind Of Write Has The Store's Default`() async throws {
    let store = try self.makeStore(defaultExpiry: .after(.seconds(1)))

    store.set("a", forKey: "value")
    [UInt8](arrayLiteral: 1, 2, 3)
      .withUnsafeBytes { _ = store.set(unsafeBytes: $0, forKey: "bytes") }
    store.set(["batch-a": 1.0, "batch-b": 2.0])
    store.set("b", for: .token)
    store.set((.token, "c"))
    try store.set(3, for: .attempts)
    try store.encode(7, forKey: "coded", with: TextCoder.shared)
    try store.encode(Session(user: "blob", isAdmin: true), intoKeysUnder: "session")
    store.set("kept", forKey: "kept", expiry: .never)
    #expect(store.count == 10)

    try await Task.sleep(for: Self.expiredAfter)

    #expect(store.keys == ["kept"])
  }

  @Test func `An Expiry Given To A Write Wins Over The Default`() async throws {
    let store = try self.makeStore(defaultExpiry: .after(.seconds(1)))

    store.set(["batch-a": 1.0, "batch-b": 2.0], expiry: .never)
    store.set("b", for: .token, expiry: .never)
    try store.set(3, for: .attempts, expiry: .never)
    try store.encode(
      Session(user: "blob", isAdmin: true),
      intoKeysUnder: "session",
      expiry: .never
    )

    try await Task.sleep(for: Self.expiredAfter)

    #expect(
      store.keys == ["batch-a", "batch-b", "token", "attempts", "session.user", "session.isAdmin"]
    )
  }

  @Test func `A Default Leaves The Values Already Stored Alone`() async throws {
    let rootDirectory = temporaryRootDirectory()
    let permanent = try self.makeStore(rootDirectory: rootDirectory)
    permanent.set("blob", forKey: "username")

    let expiring = try self.makeStore(
      rootDirectory: rootDirectory,
      defaultExpiry: .after(.seconds(1))
    )
    expiring.set("123456", forKey: "otp")
    try await Task.sleep(for: Self.expiredAfter)

    #expect(expiring.keys == ["username"])
  }

  @Test func `A Default Belongs To The Store It Was Opened With`() async throws {
    let rootDirectory = temporaryRootDirectory()
    let expiring = try self.makeStore(
      rootDirectory: rootDirectory,
      defaultExpiry: .after(.seconds(1))
    )
    let permanent = try self.makeStore(rootDirectory: rootDirectory)

    expiring.set("123456", forKey: "otp")
    permanent.set("blob", forKey: "username")
    try await Task.sleep(for: Self.expiredAfter)

    #expect(permanent.keys == ["username"])
    #expect(permanent.configuration.defaultExpiry == .never)
  }

  // MARK: - Disabling

  @Test func `Disabling Expiry Keeps What Has Not Expired For Good`() async throws {
    let store = try self.makeStore()
    store.set("blob", forKey: "username")
    store.set("123456", forKey: "otp", expiry: .after(.seconds(1)))
    #expect(store.isExpiryEnabled)

    try store.disableExpiry()

    #expect(!store.isExpiryEnabled)
    try await Task.sleep(for: Self.expiredAfter)
    #expect(store.value(forKey: "otp", as: String.self) == "123456")
    #expect(store.value(forKey: "username", as: String.self) == "blob")
    #expect(store.count == 2)
  }

  @Test func `Disabling Expiry Drops What Has Expired`() async throws {
    let store = try self.makeStore()
    store.set("blob", forKey: "username")
    store.set("123456", forKey: "otp", expiry: .after(.seconds(1)))
    try await Task.sleep(for: Self.expiredAfter)

    try store.disableExpiry()

    #expect(store.keys == ["username"])
    #expect(!store.isExpiryEnabled)
  }

  @Test func `Disabling Expiry Does Nothing To A Store Without It`() throws {
    let store = try self.makeStore()
    store.set("blob", forKey: "username")

    try store.disableExpiry()

    #expect(!store.isExpiryEnabled)
    #expect(store.keys == ["username"])
  }

  @Test func `Expiry Comes Back With The Next Write That Expires`() async throws {
    let store = try self.makeStore()
    store.set("a", forKey: "first", expiry: .after(.seconds(3_600)))
    try store.disableExpiry()

    store.set("b", forKey: "second", expiry: .after(.seconds(1)))

    #expect(store.isExpiryEnabled)
    try await Task.sleep(for: Self.expiredAfter)
    #expect(store.keys == ["first"])
  }

  @Test func `Whether Expiry Is Enabled Is Remembered By The File`() throws {
    let rootDirectory = temporaryRootDirectory()
    let store = try self.makeStore(rootDirectory: rootDirectory, mode: .multiProcess)
    store.set("123456", forKey: "otp", expiry: .after(.seconds(3_600)))
    let backup = MMKVDirectory(path: temporaryRootDirectory())
    try store.backUp(to: backup)

    let copy = try self.makeStore(rootDirectory: backup.path)

    #expect(copy.isExpiryEnabled)
    #expect(copy.value(forKey: "otp", as: String.self) == "123456")
  }

  @Test func `A Read-Only Store's Expiry Cannot Be Disabled`() throws {
    let rootDirectory = temporaryRootDirectory()
    let writable = try self.makeStore(rootDirectory: rootDirectory)
    writable.set("123456", forKey: "otp", expiry: .after(.seconds(3_600)))
    let backup = MMKVDirectory(path: temporaryRootDirectory())
    try writable.backUp(to: backup)

    let store = try self.makeStore(
      rootDirectory: backup.path,
      isReadOnly: true,
      defaultExpiry: .after(.seconds(1))
    )

    #expect(store.isExpiryEnabled)
    #expect(!store.set("blob", forKey: "username"))
    expectError(.disableExpiryFailed) {
      try store.disableExpiry()
    }
    #expect(store.isExpiryEnabled)
  }

  @Test func `A Suspended Store's Expiry Cannot Be Disabled`() throws {
    let store = try self.makeStore(mode: .multiProcess)
    store.set("123456", forKey: "otp", expiry: .after(.seconds(3_600)))
    store.suspend()

    #expect(!store.isExpiryEnabled)
    expectError(.storeIsSuspended) {
      try store.disableExpiry()
    }

    store.resume()
    #expect(store.isExpiryEnabled)
  }

  @Test func `Disabling Expiry Shows In Another Instance Over The Same Files`() throws {
    let (first, second) = try makeLinkedStores(mode: .multiProcess)
    first.set("123456", forKey: "otp", expiry: .after(.seconds(3_600)))
    #expect(second.isExpiryEnabled)

    try first.disableExpiry()

    #expect(!second.isExpiryEnabled)
    #expect(second.value(forKey: "otp", as: String.self) == "123456")
  }

  #if Foundation
    // MARK: - Dates

    @Test func `A Value Expires At A Date`() async throws {
      let store = try self.makeStore()

      store.set("soon", forKey: "soon", expiry: .at(Date().addingTimeInterval(1)))
      store.set("later", forKey: "later", expiry: .at(Date().addingTimeInterval(3_600)))
      store.set("past", forKey: "past", expiry: .at(.distantPast))
      #expect(store.keys == ["soon", "later", "past"])

      try await Task.sleep(for: .seconds(3.1))

      #expect(store.keys == ["later"])
    }

    @Test func `A Date Is Rounded Up To A Second`() {
      #expect(
        MMKVExpiry.at(Date(timeIntervalSince1970: 1_700_000_000.25))
          == .at(secondsSince1970: 1_700_000_001)
      )
      #expect(
        MMKVExpiry.at(Date(timeIntervalSince1970: 1_700_000_000))
          == .at(secondsSince1970: 1_700_000_000)
      )
    }

    @Test func `A Date Too Far Off To Record Is No Expiry`() throws {
      let store = try self.makeStore()

      store.set("blob", forKey: "username", expiry: .at(.distantFuture))
      store.set("blob", forKey: "name", expiry: .at(Date(timeIntervalSince1970: .infinity)))

      #expect(!store.isExpiryEnabled)
      #expect(store.count == 2)
    }
  #endif
}
