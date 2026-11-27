# Upstream test manifest

Every test function in MMKV v2.4.3's own test sources, and what this package does with it. The
ports live beside this file, one Swift file per upstream file, and each test names its upstream
source in its first comment. See "0b. Upstream tests" in `Docs/swift-core-migration.md`.

Statuses:

- **Ported**: a Swift test reproduces it through the public API and the store's files on disk.
  "Partly" says which part is left out and why.
- **Covered by**: an existing test already checks the same behaviour.
- **Skipped**: the package does not expose what the test exercises.
- **Deferred**: it tests internals or needs infrastructure that a later phase adds.

Conventions that apply to every port:

- Upstream reads a missing key as the default it passes in. The package reads `nil`, so the
  ports check for `nil`.
- Upstream closes a store and opens it again. The package keeps every instance open for the rest
  of the process, so the ports copy the store's files to a new identifier and open that
  (`copyFiles(of:in:to:)` in `UpstreamSupport.swift`).
- Upstream's `MMKV::isFileValid(id)` is mirrored by `StoreFiles.isValid()`, which makes the same
  check on the files: complete metadata, a data file holding the size the metadata records, and a
  matching CRC32.
- Upstream reads `actualSize()` from the instance. The ports read the same number from the
  metadata file (`StoreMetadata.actualSize`), and `totalSize()` from the data file's size.
- Upstream's store-wide default expiry (`enableKeyExpire`, `expiredInSeconds`,
  `enableAutoKeyExpire(seconds)`) is not exposed. The package enables expiration on the first
  expiring write, with no default, so the ports pass the default on each write instead.
- Upstream's unfiltered `count()` and `allKeys()` are not exposed: the package's `count` and
  `keys` always leave out expired keys.

## `POSIX/demo/UnitTest.cpp` → `UpstreamUnitTests.swift`

| Upstream | Status | Swift test and notes |
| --- | --- | --- |
| `testBool` | Ported | `Bool Round Trips` |
| `testInt32` | Ported | `Int32 Round Trips` |
| `testUInt32` | Ported | `UInt32 Round Trips` |
| `testInt64` | Ported | `Int64 Round Trips` |
| `testUInt64` | Ported | `UInt64 Round Trips` |
| `testFloat` | Ported | `Float Round Trips`. Exact equality where upstream allows 0.001. |
| `testDouble` | Ported | `Double Round Trips`. Exact equality where upstream allows 0.001. |
| `testString` | Ported | `String Round Trips` |
| `testBytes` | Ported | `Bytes Round Trip`. A missing key is `nil` where upstream reads an empty buffer. |
| `testVector` | Ported | `String Vector Round Trips` |
| `testRemove` | Ported | `Removes One Key And Several Keys` |
| `testExpirationMigrationAggregateLimit` | Deferred | Phase 4. It forges a value size near 4 GiB inside the core's dictionary (`m_dic`) so that enabling expiration overflows; nothing public can make a value that large. |
| `testOversizedKey` | Ported | `Keys Longer Than 65531 Bytes Are Rejected`; `Expiration Is Not Enabled When A Pair Would Overflow`, where upstream's `enableAutoKeyExpire()` is the package's first expiring write, and "expiration stays off" is read from the metadata's flags. |
| `testOversizedValue` | Ported | `Values Too Large For The File Are Rejected`; `Expiring Values Too Large For The File Are Rejected`. Like upstream, a one-byte buffer is passed with a length of about 4 GiB, so a core that reads it before rejecting it crashes. 64-bit only. |
| `testFileValidation` | Ported | `The Files Are Valid Until The Metadata Is Truncated`. Also opens the truncated files, which upstream does not: see the test. |
| `testTinyFileRecovery` | Ported | `A Data File Shorter Than Its Header Opens Empty`, with `recovery: .recover` for upstream's handler. Upstream also counts calls to `onMMKVFileLengthError`, which has no public equivalent. |
| `testCodedOutputBounds` | Deferred | Phase 2 (format primitives). Tests `CodedOutputData`, `CodedInputData`, and `MMBuffer` directly. |
| `testExpirationOverflow` | Ported, partly | `The Longest Expiration Saturates`. The store-wide default of `UInt32.max` seconds is not exposed; the per-key expiries of `UInt32.max` seconds are ported. |
| `testExpirationAlignment` | Ported | `Expiring Values Of Every Short Length Round Trip`; `Encrypted Expiring Values Of Every Short Length Round Trip` |
| `testArmCRC32` | Deferred | Phase 2 (format primitives: CRC32 in Swift). |
| `testCryptoRandomAndWipe` | Ported, partly | `Rekeying With The Same Key Switches To AES-256` ports the AES-128 to AES-256 switch with the same key. Deferred to phase 6: `AESCrypt::fillRandomIV` and wiping the key from a destroyed `AESCrypt`. Skipped: `checkReSetCryptKey`, which is not exposed. |
| `testDecryptToPlainKeyLimit` | Ported | `Decrypting Fails While A Key Is Too Long For A Plain Store`. Upstream's AES-128 key is 17 bytes, of which MMKV uses 16; the package rejects a key longer than the cipher's, so the port passes those 16. `clearMemoryCache()` is replaced by opening a copy with the key. |
| `testLongDirectoryWalk` | Skipped | Not exposed: `walkInDir` serves backup, restore, and listing a directory, none of which this package has. |
| `testMinimalBackupRestore` | Skipped | Not exposed: backup and restore. |
| `testCachedRestore` | Skipped | Not exposed: restore. |
| `testReadOnlyRecovery` | Ported | `A Read Only Store Recovers From The Last Confirmed Size Without Writing`. Upstream also checks the instance's `actualSize()`; the port checks that the value and keys read back instead, and compares both files byte for byte. |
| `testImportRejectedWrites` | Skipped | Not exposed: import (`importFrom`). |
| `testImportRejectsSelf` | Skipped | Not exposed: import. |
| `testImportUsesStableLockOrder` | Skipped | Not exposed: import. |
| `testBorrowedValueStorage` | Deferred | Phase 6 (encryption). Tests `KeyValueHolderCrypt` directly. |
| `testImportIntoEncrypted` | Skipped | Not exposed: import. |
| `testFirstReadAfterReopenRespectsExpiration` | Ported | `The First Read After Reopening Respects Expiration` |
| `testReadOnlyExpiration` | Ported | `A Read Only Store Filters Expired Keys`; `A Read Only Encrypted Store Filters Expired Keys`. The `keys` and `count` checks found a bug in the C++ engine's shim, since fixed (see below). The unfiltered `count(false) == 2` is not exposed. |
| `testFirstWriteAfterReopenPreservesValue` | Ported | `The First Write After Reopening Keeps Its Value` |
| `testFirstWriteAfterReopenOverloads` | Ported | `The First Write After Reopening Works For Every Type`. Leaves out `vector<int32_t>`, which the package does not store. |

## `POSIX/demo/demo.cpp` → `UpstreamDemoTests.swift`

Most of these print rather than assert. The ports assert what upstream prints, and the notes say
where they assert more. `main`, `threadFunction`, `testMMKV`, `printVector`, `getTimeInMs`,
`setReadOnly`, `to_string`, and `MyMMKVHandler` are helpers, not tests.

| Upstream | Status | Swift test and notes |
| --- | --- | --- |
| `functionalTest` | Ported | `Every Value Type Round Trips And Survives A Reopen`. Setting a null C string, which removes the key, is ported as a removal. Also reused by `testReadOnly` and `testReKey`. |
| `containerTest` | Ported, partly | Within `functionalTest`'s port: the `vector<string>`. The C++20 vectors of `bool`, integers, and floating-point numbers are not exposed. |
| `threadTest` | Ported | `Threads Writing Through Their Own Opens Keep Every Key`: 10 threads, 10,000 integer and string pairs, each thread opening the store itself. |
| `brutleTest` | Covered by | `Benchmarks`: `write.int32/*` and `write.string/*`. It only times writes. |
| `processTest` | Deferred | Needs the helper executable (phase 5). In-process equivalent covered by `MMKVStoreMultiProcessTests/Multi Process Stores Stay Consistent Under Concurrent Writes`. |
| `testInterProcessLock` | Ported, in process | The parent side of `TestInterProcessLock.cpp`; see that file's table. |
| `cornetSizeTest` | Ported | `A Value That Exactly Fills The First Page Survives A Trim`. Upstream asserts nothing; the port checks the value reads back, the files are valid, and a reopened copy reads it. Upstream's `main` leaves this commented out. |
| `itemSizeHolderTest` | Ported | `A Single Bool Survives A Reload`; `A Single Encrypted Bool Survives A Reload`. Upstream's comment ("you won't find the key") describes an old bug and asserts nothing; the port checks the key is found. |
| `fastRemoveCornetSizeTest` | Ported | `Setting And Removing A Sixteenth Of A Page Keeps The File Valid`. Upstream asserts nothing; the port checks the files stay valid and a reopened copy reads a final write. Commented out in upstream's `main`. |
| `testClearEmptyMMKV` | Ported | `Clearing A Store Twice`. Commented out in upstream's `main`. |
| `testClearAllKeepSpace` | Ported | `Clearing While Keeping Capacity Keeps The File Size`; `Clearing An Encrypted Store While Keeping Capacity Keeps The File Size` |
| `testBackup` | Skipped | Not exposed: backup. |
| `testRestore` | Skipped | Not exposed: restore. |
| `testAutoExpiration` | Ported, partly | `Values That Never Expire Outlive Expiring Ones`; `A Key Set Again After Its Removal Takes Its New Expiry`. Upstream enables expiration through the configuration with a one-second default that expires a key written before expiration was on; neither is exposed, so that key is given its own one-second expiry. Upstream's `count(true)` and `allKeys(true)` prints are asserted. |
| `testExpectedCapacity` | Ported | `The Expected Capacity Sets The Initial File Size In Whole Pages`; `Reopening With A Larger Expected Capacity Grows The File But Never Shrinks It`; `An Expected Capacity Of The Pairs' Size Needs No Growth`, which asserts what upstream's "0 times expand" comments claim. `totalSize()` is read as the data file's size. |
| `testOnlyOneKey` | Ported | `Overwriting One Key Over And Over`; `Overwriting One Encrypted Key Over And Over`; `Overwriting One Encrypted Expiring Key Over And Over` |
| `testOverride` | Ported | `Setting And Removing Keys Then Reopening`; `Setting And Removing Encrypted Expiring Keys Then Reopening` |
| `testGetStringSpeed` | Covered by | `Benchmarks`: `read.string/*`. It only times reads. Commented out in upstream's `main`. |
| `testCompareBeforeSet` | Ported | `Setting An Identical Value Writes Nothing`; `A Value Of Another Type Is Never Taken For An Identical One`; `Setting An Identical Empty String Writes Nothing`. `actualSize()` is read from the metadata file. |
| `testFtruncateFail` | Deferred | Phase 3: needs the Swift core's file-system seam. Upstream lowers `RLIMIT_FSIZE` for the whole process, which would break every other test running alongside it. Commented out in upstream's `main`. |
| `testRemoveStorage` | Skipped | Not exposed: `removeStorage`. |
| `testReadOnly` | Ported | `A Read Only Store Reads Everything And Refuses Writes`. Upstream only checks that writing does not crash; the package's shim refuses every write and removal, which the port asserts. |
| `testNameSpace` | Covered by | Every test: the package opens each store through `MMKV::nameSpace(rootDirectory)`, and every test uses a root directory of its own. |
| `testImport` | Skipped | Not exposed: import. |
| `testReKey` | Ported | `Rekeying Through Every Cipher Keeps Every Value`. The identifier drops upstream's `/`, which makes MMKV name the files after an MD5 that the ports cannot find by identifier. |
| `testReadonlyCrash` | Ported | `A Read Only Store Without Files Reads Nothing` |
| `testOversizedKey` | Ported | `Keys Longer Than 65531 Bytes Are Rejected Without Harm` |

## `POSIX/demo/TestSingleKeyIV.cpp` → `UpstreamSingleKeyIVTests.swift`

Upstream's `main` runs `overwriteSizes` four times; each run is a Swift test. `snapshot`,
`reloadAndReopen`, `verifyString`, `preservesCiphertextAndAppends`, `checkEncryptedReplacement`,
`securityRegression`, `readFile`, `openKV`, `require`, `check`, and `OwnedDirectory` are helpers,
ported as such.

| Upstream | Status | Swift test and notes |
| --- | --- | --- |
| `overwriteSizes` (aes128) | Ported | `Overwriting An AES-128 Key Never Reuses Keystream`, with `securityRegression`. |
| `overwriteSizes` (aes256) | Ported | `Overwriting An AES-256 Key Never Reuses Keystream`, with `securityRegression`. |
| `overwriteSizes` (expiry) | Ported | `Overwriting An Encrypted Expiring Key Never Reuses Keystream` |
| `overwriteSizes` (plain) | Ported | `Overwriting A Plain Key Keeps The Files Valid` |
| `capacityGrowth` | Ported | `Overwriting After The File Grows Never Reuses Keystream` |
| `borrowedInput` | Ported | `Overwriting With Borrowed Bytes Copies Them` |
| `dictionaryTransitions` | Ported | `Appending And Emptying After An Overwrite` |
| `forcedCompaction` | Ported | `Compaction Writes A Fresh IV` |

Upstream's `require(meta.m_actualSize == kv->actualSize())` compares the file with the instance,
which the package cannot read; the snapshots use the metadata's size.

## `POSIX/demo/TestThreadLock.cpp` → `UpstreamThreadLockTests.swift`

| Upstream | Status | Swift test and notes |
| --- | --- | --- |
| `destroyUnlockedLock` | Skipped | Destroys a C++ `ThreadLock`. The package never closes or destroys an instance, so no lock is ever destroyed. |
| `destroyLockedOnce` | Skipped | As `destroyUnlockedLock`, with the lock held. |
| `destroyRecursivelyLocked` | Skipped | As `destroyUnlockedLock`, with the lock held three times. |
| `tryLockTracksOwnership` | Deferred | Phase 5 (the recursive lock). Tests `ThreadLock::try_lock` directly; the package has no counterpart of upstream's `try_lock_thread()`. |
| `normalLockStillWorks` | Covered by | `MMKVStoreKeyTests/With Exclusive Lock Is Reentrant And Returns The Body's Result` |
| `concurrentLockingTracksOwnership` | Ported | `Concurrent Locking Loses No Update`: 8 threads, 10,000 increments each, under `withExclusiveLock`. |

## `POSIX/demo/TestInterProcessLock.cpp` → `UpstreamInterProcessLockTests.swift`

| Upstream | Status | Swift test and notes |
| --- | --- | --- |
| `threadTest` (with `main` and `threadFunction`) | Ported, in process | `Readers Wait For Another Instance's Exclusive Lock`, over `makeLinkedStores(mode: .multiProcess)`. The version with a real second process is deferred: it needs the helper executable (phase 5). |

## `POSIX/demo/TestRemoveStorage.cpp`

| Upstream | Status | Swift test and notes |
| --- | --- | --- |
| `normalDeletion` | Skipped | Not exposed: `removeStorage`, `checkExist`, and `close`. |
| `writerOrdering` | Skipped | Not exposed: `removeStorage`. It also interposes `pthread_mutex_lock` and `flock`, which would be deferred to phase 3's file-system seam. |
| `crossProcessExclusion` | Skipped | Not exposed: `removeStorage`. It also interposes `unlink` and forks a probe process. |

## `POSIX/demo/TestFileCopy.cpp`

| Upstream | Status | Swift test and notes |
| --- | --- | --- |
| `main` (copy with short, interrupted, and zero-length transfers) | Deferred | Phase 3: needs the Swift core's file-system seam to inject the failures. `copyFileContent` itself serves backup and restore, which are not exposed. |

## `iOS/MMKVDemo/MMKVDemoTests/MMKVDemoTests.mm` → `UpstreamIOSDemoTests.swift`

| Upstream | Status | Swift test and notes |
| --- | --- | --- |
| `testBool` | Covered by | `UpstreamUnitTests/Bool Round Trips` |
| `testInt32` | Covered by | `UpstreamUnitTests/Int32 Round Trips` |
| `testInt64` | Ported | `Int64 Max Round Trips`: `Int64.max`, where `UnitTest.cpp` uses `Int64.min`. |
| `testUInt32` | Covered by | `UpstreamUnitTests/UInt32 Round Trips` |
| `testUInt64` | Covered by | `UpstreamUnitTests/UInt64 Round Trips` |
| `testFloat` | Covered by | `UpstreamUnitTests/Float Round Trips` |
| `testDouble` | Covered by | `UpstreamUnitTests/Double Round Trips` |
| `testNSString` | Covered by | `UpstreamUnitTests/String Round Trips`, which writes the same string. |
| `testNSStringForNewGetSet` | Covered by | `UpstreamUnitTests/String Round Trips` |
| `testNSData` | Covered by | `UpstreamUnitTests/Bytes Round Trip`, which writes the same bytes, and `MMKVFoundationTests/Data Round Trips As Raw Bytes`. |
| `testNSDataForNewGetSet` | Covered by | As `testNSData`. |
| `testNSDate` | Skipped | Not exposed: `NSDate`. |
| `testNSDateForNewGetSet` | Skipped | Not exposed: `NSDate`. |
| `testNSDictionary` | Skipped | Not exposed: `NSCoding` objects. |
| `testNSMutableDictionary` | Skipped | Not exposed: `NSCoding` objects. |
| `testNSArray` | Skipped | Not exposed: `NSCoding` objects. |
| `testNSMutableArray` | Skipped | Not exposed: `NSCoding` objects. |
| `testNSSet` | Skipped | Not exposed: `NSCoding` objects. |
| `testNSMutableSet` | Skipped | Not exposed: `NSCoding` objects. |
| `testCustomNSCodingObject` | Skipped | Not exposed: `NSCoding` objects. |
| `testCustomNSCodingObjectInArray` | Skipped | Not exposed: `NSCoding` objects. |
| `testRemove` | Covered by | `UpstreamUnitTests/Removes One Key And Several Keys`, the same scenario with a vector where this writes an `NSDictionary`. |
| `testEnumerateExpiredKeys` | Ported, partly | `Expired Keys Are Not Listed`. Ports the `nonExpiredOnly` run: `keys` filters like `enumerateNonExpiredKeys:`. The unfiltered `enumerateKeys:`, stopping an enumeration early, and the unfiltered `count` of 17 are not exposed. |
| `testEnumerateExpiredKeysEncrypted` | Ported, partly | `Expired Encrypted Keys Are Not Listed`, as above. |
| `testKeysExpireDuringEnumeration` | Ported, partly | `Keys That Expire After Being Listed Read As Missing`. `keys` is a snapshot, so keys expire after it returns rather than inside a callback. |
| `testKeysExpireDuringEnumerationEncrypted` | Ported, partly | `Encrypted Keys That Expire After Being Listed Read As Missing`, as above. |
| `testExpirationOverflow` | Covered by | `UpstreamUnitTests/The Longest Expiration Saturates`. The extra `NSArray` value is an `NSCoding` object. |
| `testCloseIsIdempotentAndAllowsReopen` | Skipped | Not exposed: `close`. |
| `testConcurrentGetAndAutoCleanupOwnershipHandoff` | Ported, partly | `Opening One Store Concurrently From Many Threads`: 8 threads opening the store and writing 2,000 times each. `tryAutoCleanUpInstances` is Objective-C only, and the package never releases an instance. |
| `testImportFromNSUserDefaults` | Skipped | Not exposed: `NSUserDefaults` migration. |
| `testMultiTimesOverwriteValue` | Ported | `Overwriting One Value A Million Times`, with a seeded generator in place of `rand()`. |

`compareDate:withDate:` and `checkEnumerationWithCryptKey:…` are helpers.

## `iOS/MMKVDemo/MMKVDemoTests/MMKVPerformanceTest.mm`

| Upstream | Status | Swift test and notes |
| --- | --- | --- |
| `testWriteIntPerformance` | Covered by | `Benchmarks`: `write.int32/*` |
| `testReadIntPerformance` | Covered by | `Benchmarks`: `read.int32/*` |
| `testWriteStringPerformance` | Covered by | `Benchmarks`: `write.string/*` |
| `testReadStringPerformance` | Covered by | `Benchmarks`: `read.string/*` |

## Fixed while porting

- **The first `keys` or `count` on an instance did not filter expired keys** (C++ engine).
  `mmkv_count` and `mmkv_keys` in `SwiftMMKVShim.cpp` called `count(kv->isExpirationEnabled())`
  and `allKeys(kv->isExpirationEnabled())`, but that flag is only filled from the metadata when
  the instance loads, which `count` and `allKeys` do after their argument is evaluated. The shim
  now passes `true`, since both check the flag themselves after loading. `A Read Only Store
  Filters Expired Keys` in `UpstreamUnitTests` covers it.
