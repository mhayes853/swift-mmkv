#if canImport(Darwin)
  import Darwin
  import Foundation
  import SwiftMMKV
  import Testing

  /// Data protection is only enforced on a device, so these tests read the class of a store's
  /// files back. They say nothing about what a locked device does with a file.
  @Suite struct MMKVFileProtectionTests {
    private static let complete: Int32 = 1
    private static let completeUnlessOpen: Int32 = 2
    private static let untilFirstUserAuthentication: Int32 = 3

    /// Whether files here keep a protection class they are given, which they do not on a
    /// volume without data protection.
    private static let isSupported: Bool = {
      let path = strictRootDirectory() + "/probe"
      FileManager.default.createFile(atPath: path, contents: nil)
      return protectionClass(path) == complete
    }()

    /// A directory whose new files are given the strictest class, as every directory of an app
    /// with the data protection entitlement set to `complete` does. A file the core made anew
    /// in it, in place of one it was given, would therefore show.
    private static func strictRootDirectory() -> String {
      let rootDirectory = temporaryRootDirectory()
      setProtectionClass(complete, rootDirectory, flags: O_RDONLY)
      return rootDirectory
    }

    private static func protectionClass(_ path: String) -> Int32? {
      let descriptor = open(path, O_RDONLY | O_CLOEXEC)
      guard descriptor >= 0 else { return nil }
      defer { close(descriptor) }
      let protectionClass = fcntl(descriptor, F_GETPROTECTIONCLASS)
      return protectionClass < 0 ? nil : protectionClass
    }

    @discardableResult
    private static func setProtectionClass(
      _ protectionClass: Int32,
      _ path: String,
      flags: Int32 = O_RDWR
    ) -> Bool {
      let descriptor = open(path, flags | O_CLOEXEC)
      guard descriptor >= 0 else { return false }
      defer { close(descriptor) }
      // A change that closely follows another to the same file is turned away as busy.
      for _ in 0..<50 {
        if fcntl(descriptor, F_SETPROTECTIONCLASS, protectionClass) == 0 { return true }
        guard errno == EBUSY else { return false }
        usleep(200)
      }
      return false
    }

    /// The classes of a store's data file and of its `.crc` file.
    private func protectionClasses(id: String, in rootDirectory: String) -> [Int32?] {
      ["", ".crc"].map { Self.protectionClass("\(rootDirectory)/\(id)\($0)") }
    }

    private func configuration(
      id: MMKVStore.ID = "settings",
      rootDirectory: String,
      mode: MMKVConfiguration.Mode = .singleProcess,
      isReadOnly: Bool = false,
      encryption: MMKVConfiguration.Encryption? = nil,
      fileProtection: MMKVConfiguration.FileProtection? = nil
    ) -> MMKVConfiguration {
      var configuration = MMKVConfiguration(
        id: id,
        directory: MMKVDirectory(path: rootDirectory),
        mode: mode,
        isReadOnly: isReadOnly,
        encryption: encryption
      )
      if let fileProtection {
        configuration.fileProtection = fileProtection
      }
      return configuration
    }

    /// Creates a store's files with the class a stricter app would give them, without opening
    /// the store.
    private func makeStrictStoreFiles(
      id: String = "settings",
      protectionClass: Int32 = MMKVFileProtectionTests.complete
    ) throws -> String {
      let rootDirectory = Self.strictRootDirectory()
      try makeUnopenedStoreFiles(at: "\(rootDirectory)/\(id)")
      for suffix in ["", ".crc"] {
        #expect(Self.setProtectionClass(protectionClass, "\(rootDirectory)/\(id)\(suffix)"))
      }
      #expect(
        self.protectionClasses(id: id, in: rootDirectory) == [protectionClass, protectionClass]
      )
      return rootDirectory
    }

    @Test func `The Default Is Until First User Authentication`() {
      let configuration = MMKVConfiguration(
        directory: MMKVDirectory(path: "/tmp"),
        mode: .singleProcess
      )
      #expect(configuration.fileProtection == .completeUntilFirstUserAuthentication)
      #expect(MMKVConfiguration.temporary().fileProtection == .completeUntilFirstUserAuthentication)
    }

    @Test(.enabled(if: isSupported))
    func `A New Store's Files Are Given The Class`() throws {
      let rootDirectory = Self.strictRootDirectory()
      _ = try MMKVStore(self.configuration(rootDirectory: rootDirectory))

      #expect(
        self.protectionClasses(id: "settings", in: rootDirectory)
          == [Self.untilFirstUserAuthentication, Self.untilFirstUserAuthentication]
      )
    }

    @Test(
      .enabled(if: isSupported),
      arguments: [MMKVFileProtectionTests.complete, MMKVFileProtectionTests.completeUnlessOpen]
    )
    func `A Stricter Class Is Relaxed When The Store Is Opened`(strict: Int32) throws {
      let rootDirectory = try self.makeStrictStoreFiles(protectionClass: strict)

      let store = try MMKVStore(self.configuration(rootDirectory: rootDirectory))

      #expect(
        self.protectionClasses(id: "settings", in: rootDirectory)
          == [Self.untilFirstUserAuthentication, Self.untilFirstUserAuthentication]
      )
      #expect(store.value(forKey: "key", as: String.self) == "value")
    }

    @Test(.enabled(if: isSupported))
    func `Unchanged Leaves A Stricter Class Alone`() throws {
      let rootDirectory = try self.makeStrictStoreFiles()

      let store = try MMKVStore(
        self.configuration(rootDirectory: rootDirectory, fileProtection: .unchanged)
      )
      _ = try MMKVStore(
        self.configuration(id: "new", rootDirectory: rootDirectory, fileProtection: .unchanged)
      )
      #expect(
        self.protectionClasses(id: "new", in: rootDirectory) == [Self.complete, Self.complete]
      )

      #expect(
        self.protectionClasses(id: "settings", in: rootDirectory)
          == [Self.complete, Self.complete]
      )
      #expect(store.value(forKey: "key", as: String.self) == "value")
    }

    @Test(.enabled(if: isSupported))
    func `A Read-Only Store's Files Are Left Alone`() throws {
      let rootDirectory = try self.makeStrictStoreFiles()

      let store = try MMKVStore(self.configuration(rootDirectory: rootDirectory, isReadOnly: true))

      #expect(
        self.protectionClasses(id: "settings", in: rootDirectory)
          == [Self.complete, Self.complete]
      )
      #expect(store.value(forKey: "key", as: String.self) == "value")
    }

    @Test(.enabled(if: isSupported))
    func `No Protection Is Accepted`() throws {
      let rootDirectory = try self.makeStrictStoreFiles()

      _ = try MMKVStore(self.configuration(rootDirectory: rootDirectory, fileProtection: .none))

      // macOS accepts the class and goes on reporting the one above it.
      let classes = self.protectionClasses(id: "settings", in: rootDirectory)
      #expect(classes[0] == classes[1])
      #expect(classes[0] == 4 || classes[0] == Self.untilFirstUserAuthentication)
    }

    @Test(.enabled(if: isSupported))
    func `Opening A Store Again Applies The Class Again`() throws {
      let rootDirectory = temporaryRootDirectory()
      let configuration = self.configuration(rootDirectory: rootDirectory)
      _ = try MMKVStore(configuration)
      for suffix in ["", ".crc"] {
        Self.setProtectionClass(Self.complete, "\(rootDirectory)/settings\(suffix)")
      }

      _ = try MMKVStore(configuration)

      #expect(
        self.protectionClasses(id: "settings", in: rootDirectory)
          == [Self.untilFirstUserAuthentication, Self.untilFirstUserAuthentication]
      )
    }

    @Test(.enabled(if: isSupported))
    func `A Store With A Hashed Identifier Has Its Files Given The Class`() throws {
      let rootDirectory = Self.strictRootDirectory()

      _ = try MMKVStore(self.configuration(id: "a/b", rootDirectory: rootDirectory))

      let hashedDirectory = "\(rootDirectory)/specialCharacter"
      let names = try FileManager.default.contentsOfDirectory(atPath: hashedDirectory)
      #expect(names.count == 2)
      for name in names {
        #expect(
          Self.protectionClass("\(hashedDirectory)/\(name)") == Self.untilFirstUserAuthentication
        )
      }
    }

    @Test(
      .enabled(if: isSupported),
      arguments: [MMKVConfiguration.Mode.singleProcess, .multiProcess]
    )
    func `Encrypted And Shared Stores Are Given The Class`(mode: MMKVConfiguration.Mode) throws {
      let rootDirectory = Self.strictRootDirectory()
      let store = try MMKVStore(
        self.configuration(
          rootDirectory: rootDirectory,
          mode: mode,
          encryption: .aes256(key: "secret")
        )
      )
      store.set("dark", forKey: "theme")

      #expect(
        self.protectionClasses(id: "settings", in: rootDirectory)
          == [Self.untilFirstUserAuthentication, Self.untilFirstUserAuthentication]
      )
    }

    /// The class is given once, when the store is opened, so everything the core does to the
    /// files afterwards has to leave them the same files.
    @Test(.enabled(if: isSupported))
    func `The Class Survives What The Core Does To An Open Store's Files`() throws {
      let rootDirectory = try self.makeStrictStoreFiles()
      let store = try MMKVStore(self.configuration(rootDirectory: rootDirectory))
      let expected = [Self.untilFirstUserAuthentication, Self.untilFirstUserAuthentication]
      func classes() -> [Int32?] {
        self.protectionClasses(id: "settings", in: rootDirectory)
      }

      // Growing the file several times over.
      let large = String(repeating: "x", count: 64 * 1024)
      for index in 0..<16 {
        store.set(large, forKey: "large-\(index)")
      }
      #expect(classes() == expected)

      // Rewriting the file to drop what was overwritten.
      for _ in 0..<8 {
        store.set(large, forKey: "large-0")
      }
      store.sync()
      #expect(classes() == expected)

      try store.rekey(.aes128(key: "secret"))
      #expect(classes() == expected)
      try store.rekey(nil)
      #expect(classes() == expected)

      let backup = MMKVDirectory(path: temporaryRootDirectory())
      try store.backUp(to: backup)
      #expect(classes() == expected)

      store.removeAll(keepingCapacity: true)
      #expect(classes() == expected)
      store.set(large, forKey: "large")
      store.removeAll()
      #expect(classes() == expected)
      store.trim()
      #expect(classes() == expected)

      #expect(try store.restore(from: backup))
      #expect(classes() == expected)
      #expect(store.value(forKey: "large-0", as: String.self) == large)
    }

    @Test(.enabled(if: isSupported))
    func `Restoring Through The Directory Leaves An Open Store's Class`() throws {
      let rootDirectory = Self.strictRootDirectory()
      let store = try MMKVStore(self.configuration(rootDirectory: rootDirectory))
      store.set("dark", forKey: "theme")
      let directory = MMKVDirectory(path: rootDirectory)
      let backup = MMKVDirectory(path: temporaryRootDirectory())
      try directory.backUpAllStores(to: backup)
      for suffix in ["", ".crc"] {
        Self.setProtectionClass(Self.complete, "\(backup.path)/settings\(suffix)")
      }

      #expect(try directory.restoreAllStores(from: backup) == 1)

      #expect(
        self.protectionClasses(id: "settings", in: rootDirectory)
          == [Self.untilFirstUserAuthentication, Self.untilFirstUserAuthentication]
      )
    }
  }
#endif
