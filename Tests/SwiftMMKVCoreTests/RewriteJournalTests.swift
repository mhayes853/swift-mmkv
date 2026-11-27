import Foundation
import Testing

@testable import _SwiftMMKVCore

// What a store holds after its process stops at each point of rewriting its file. A rewrite's
// writes to the mapped files cannot be interrupted from here, so each test builds the files a
// process would leave behind from those of a rewrite that ran to its end.
@Suite struct RewriteJournalTests {
  private static let keys = (0..<50).map { "key-\($0)" }
  private static let removed = Array(keys.prefix(25))

  @Test func `A Rewrite Stopped Part Way Leaves The Store As It Was`() throws {
    let rewrite = try Rewrite { _ = $0.removeValues(forKeys: Self.removed) }
    // The first half of the data rewritten, the rest and the metadata not.
    var data = rewrite.before.data
    data.replaceSubrange(0..<2_000, with: rewrite.after.data[0..<2_000])
    let root = try rewrite.makeFiles(data: data, meta: rewrite.before.meta, hasJournal: true)

    let store = makeStore(root: root)
    expectEveryKey(in: store)
    // The store goes on working, and what it now holds is what a later load finds.
    _ = store.set(.int32(-1), forKey: "later", expiresInSeconds: 0)
    let reopened = makeStore(root: root)
    expectEveryKey(in: reopened)
    #expect(reopened.int32(forKey: "later") == -1)
  }

  @Test func `A Rewrite Stopped Before Its Metadata Leaves The Store As It Was`() throws {
    let rewrite = try Rewrite { _ = $0.removeValues(forKeys: Self.removed) }
    let root = try rewrite.makeFiles(
      data: rewrite.after.data,
      meta: rewrite.before.meta,
      hasJournal: true
    )
    expectEveryKey(in: makeStore(root: root))
  }

  @Test func `A Rewrite Stopped Part Way Through Its Metadata Leaves The Store As It Was`() throws {
    let rewrite = try Rewrite { _ = $0.removeValues(forKeys: Self.removed) }
    // Everything written but the checksum and the sequence number, which are written last.
    var meta = rewrite.after.meta
    meta.replaceSubrange(0..<4, with: rewrite.before.meta[0..<4])
    meta.replaceSubrange(8..<12, with: rewrite.before.meta[8..<12])
    let root = try rewrite.makeFiles(data: rewrite.after.data, meta: meta, hasJournal: true)
    expectEveryKey(in: makeStore(root: root))
  }

  @Test func `A Rewrite Stopped Before Its Sequence Number Is Kept`() throws {
    let rewrite = try Rewrite { _ = $0.removeValues(forKeys: Self.removed) }
    var meta = rewrite.after.meta
    meta.replaceSubrange(8..<12, with: rewrite.before.meta[8..<12])
    let root = try rewrite.makeFiles(data: rewrite.after.data, meta: meta, hasJournal: true)

    let store = makeStore(root: root)
    expectRemainingKeys(in: store)
  }

  @Test func `A Rewrite Stopped Before Deleting Its Journal Is Kept`() throws {
    let rewrite = try Rewrite { _ = $0.removeValues(forKeys: Self.removed) }
    let root = try rewrite.makeFiles(
      data: rewrite.after.data,
      meta: rewrite.after.meta,
      hasJournal: true
    )
    let store = makeStore(root: root)
    expectRemainingKeys(in: store)
  }

  @Test func `A Journal That Was Not Written Whole Is Ignored`() throws {
    let rewrite = try Rewrite { _ = $0.removeValues(forKeys: Self.removed) }
    let root = try rewrite.makeFiles(
      data: rewrite.before.data,
      meta: rewrite.before.meta,
      hasJournal: false
    )
    try writeFile(Array(rewrite.journal.prefix(1_000)), atPath: "\(root)/store.journal")
    let store = makeStore(root: root)
    expectEveryKey(in: store)
  }

  @Test func `A Stopped Change Of Key Leaves The Store Readable With The Old Key`() throws {
    let (old, new) = (Array("the old key".utf8), Array("the new key".utf8))
    let rewrite = try Rewrite(encryptionKey: old) { _ = $0.rekey(key: new, isAES256: false) }
    // The data is encrypted with the new key and a new IV, which only the metadata records.
    let stopped = try rewrite.makeFiles(
      data: rewrite.after.data,
      meta: rewrite.before.meta,
      hasJournal: true
    )
    expectEveryKey(in: makeStore(root: stopped, encryptionKey: old))

    let ended = try rewrite.makeFiles(
      data: rewrite.after.data,
      meta: rewrite.after.meta,
      hasJournal: true
    )
    expectEveryKey(in: makeStore(root: ended, encryptionKey: new))
  }

  @Test func `A Stopped Turning On Of Expiry Leaves The Store Without It`() throws {
    // The first expiring write gives every value in the store an expiry time.
    let rewrite = try Rewrite {
      _ = $0.set(.int32(1), forKey: "expiring", expiresInSeconds: 3_600)
    }
    let root = try rewrite.makeFiles(
      data: rewrite.after.data,
      meta: rewrite.before.meta,
      hasJournal: true
    )
    let store = makeStore(root: root)
    expectEveryKey(in: store)
    #expect(store.int32(forKey: "expiring") == nil)
  }

  @Test func `Another Process Restores A Rewrite That Stopped`() throws {
    let rewrite = try Rewrite(isMultiProcess: true) { _ = $0.removeValues(forKeys: Self.removed) }
    let root = try rewrite.makeFiles(
      data: rewrite.before.data,
      meta: rewrite.before.meta,
      hasJournal: false
    )
    // The other process loaded the store before the rewrite began.
    var previousMeta = rewrite.before.meta
    let sequence = previousMeta.withUnsafeBytes { MetaInfo(reading: $0.baseAddress!).sequence }
    withUnsafeBytes(of: (sequence &- 1).littleEndian) {
      previousMeta.replaceSubrange(8..<12, with: $0)
    }
    try overwriteFile(previousMeta, atPath: "\(root)/store.crc")
    let other = makeStore(root: root, isMultiProcess: true)
    #expect(other.count == Self.keys.count)

    try writeFile(rewrite.journal, atPath: "\(root)/store.journal")
    try overwriteFile(rewrite.before.meta, atPath: "\(root)/store.crc")
    try overwriteFile(rewrite.after.data, atPath: "\(root)/store")

    expectEveryKey(in: other)
    expectEveryKey(in: makeStore(root: root, isMultiProcess: true))
  }

  @Test func `The Journal Of A Rewrite That Ended Is Not Restored`() throws {
    let rewrite = try Rewrite { _ = $0.removeValues(forKeys: Self.removed) }
    #expect(rewrite.journal.count == MetaInfo.size + 4 + 4 + Int(rewrite.before.actualSize))
    // A small journal stays where it is for the next rewrite to write over.
    #expect(try readFile(atPath: "\(rewrite.root)/store.journal") == rewrite.journal)
    expectRemainingKeys(in: makeStore(root: rewrite.root))
  }

  @Test func `A Large Journal Is Emptied Once Its Rewrite Ends`() throws {
    let root = temporaryDirectory()
    let store = makeStore(root: root)
    let value = [UInt8](repeating: 1, count: 10_000)
    for index in 0..<40 {
      _ = value.withUnsafeBytes {
        store.set(.bytes($0), forKey: "key-\(index)", expiresInSeconds: 0)
      }
    }
    #expect(store.removeValues(forKeys: ["key-0", "key-1"]))
    #expect(try readFile(atPath: "\(root)/store.journal").isEmpty)
    #expect(makeStore(root: root).count == 38)
  }

  private func expectEveryKey(
    in store: StoreInstance,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(Set(store.keys).isSuperset(of: Self.keys), sourceLocation: sourceLocation)
    for (index, key) in Self.keys.enumerated() {
      #expect(store.int32(forKey: key) == Int32(index), sourceLocation: sourceLocation)
    }
  }

  private func expectRemainingKeys(
    in store: StoreInstance,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(
      Set(store.keys) == Set(Self.keys).subtracting(Self.removed),
      sourceLocation: sourceLocation
    )
    for (index, key) in Self.keys.enumerated() where index >= Self.removed.count {
      #expect(store.int32(forKey: key) == Int32(index), sourceLocation: sourceLocation)
    }
  }
}

/// A store's files just before a rewrite touched its data, with the journal written, and once the
/// rewrite ended.
private struct Rewrite {
  struct Files {
    var data = [UInt8]()
    var meta = [UInt8]()

    var actualSize: UInt32 {
      self.meta.withUnsafeBytes { MetaInfo(reading: $0.baseAddress!).actualSize }
    }
  }

  let root = temporaryDirectory()
  var before = Files()
  var after = Files()
  var journal = [UInt8]()

  /// Fills a store with fifty keys, then runs `rewrite`, which must rewrite its file once.
  init(
    encryptionKey: [UInt8]? = nil,
    isMultiProcess: Bool = false,
    _ rewrite: (StoreInstance) -> Void
  ) throws {
    let root = self.root
    let captured = LockedValue<(journal: [UInt8], before: Files)?>(nil)
    let isRewriting = LockedValue(false)
    var fileSystem = FileSystem.live
    // The journal is whole once its last write returns, before the rewrite touches the data.
    fileSystem.write = { descriptor, buffer, count in
      let written = FileSystem.live.write(descriptor, buffer, count)
      if isRewriting.get(), captured.get() == nil,
        let journal = try? readFile(atPath: "\(root)/store.journal"),
        journal.count > MetaInfo.size + 4,
        journal.count == MetaInfo.size + 4 + journaledSize(journal)
      {
        let before = Files(
          data: try! readFile(atPath: "\(root)/store"),
          meta: try! readFile(atPath: "\(root)/store.crc")
        )
        captured.set((journal, before))
      }
      return written
    }
    let store = makeStore(
      root: root,
      isMultiProcess: isMultiProcess,
      encryptionKey: encryptionKey,
      fileSystem: fileSystem
    )
    for index in 0..<50 {
      _ = store.set(.int32(Int32(index)), forKey: "key-\(index)", expiresInSeconds: 0)
    }
    isRewriting.set(true)
    rewrite(store)
    isRewriting.set(false)
    store.sync(synchronously: false)
    let (journal, before) = try #require(captured.get())
    self.journal = journal
    self.before = before
    self.after = Files(
      data: try readFile(atPath: "\(root)/store"),
      meta: try readFile(atPath: "\(root)/store.crc")
    )
  }

  /// A directory holding a store with these files.
  func makeFiles(data: [UInt8], meta: [UInt8], hasJournal: Bool) throws -> String {
    let root = temporaryDirectory()
    try writeFile(data, atPath: "\(root)/store")
    try writeFile(meta, atPath: "\(root)/store.crc")
    if hasJournal {
      try writeFile(self.journal, atPath: "\(root)/store.journal")
    }
    return root
  }
}

private func makeStore(
  root: String,
  isMultiProcess: Bool = false,
  encryptionKey: [UInt8]? = nil,
  fileSystem: FileSystem = .live
) -> StoreInstance {
  StoreInstance(
    StoreConfiguration(
      id: "store",
      rootDirectory: root,
      isMultiProcess: isMultiProcess,
      encryptionKey: encryptionKey,
      fileSystem: fileSystem
    ),
    root: root
  )
}

/// The size a journal records for what follows its header.
private func journaledSize(_ journal: [UInt8]) -> Int {
  Int(journal.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: MetaInfo.size, as: UInt32.self) })
}

/// Writes `bytes` over the start of a file that is mapped, without making it shorter first.
private func overwriteFile(_ bytes: [UInt8], atPath path: String) throws {
  let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
  defer { try? handle.close() }
  try handle.seek(toOffset: 0)
  try handle.write(contentsOf: Data(bytes))
}
