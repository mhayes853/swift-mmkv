#if canImport(Observation)
  import Observation
  import SwiftMMKV
  import Synchronization
  import Testing

  @Suite struct MMKVSuspensionObservationTests {
    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    final class Changes: Sendable {
      private let storage = Mutex(0)

      var count: Int { self.storage.withLock { $0 } }

      /// Reads `isSuspended` and counts the next change to it.
      func track(_ store: MMKVStore) {
        withObservationTracking {
          _ = store.isSuspended
        } onChange: {
          self.storage.withLock { $0 += 1 }
        }
      }
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    @Test func `Suspending And Resuming A Store Are Observed`() throws {
      let store = try makeStore(mode: .multiProcess)
      let changes = Changes()

      changes.track(store)
      #expect(changes.count == 0)
      store.suspend()
      #expect(changes.count == 1)
      #expect(store.isSuspended)

      changes.track(store)
      store.resume()
      #expect(changes.count == 2)
      #expect(!store.isSuspended)
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    @Test func `Suspending A Suspended Store Is Not Observed`() throws {
      let store = try makeStore(mode: .multiProcess)
      let changes = Changes()
      store.suspend()

      changes.track(store)
      store.suspend()
      #expect(changes.count == 0)

      store.resume()
      #expect(changes.count == 1)
      changes.track(store)
      store.resume()
      #expect(changes.count == 1)
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    @Test func `Every Store Over The Same Files Is Observed Together`() throws {
      let rootDirectory = temporaryRootDirectory()
      let first = try makeStore(rootDirectory: rootDirectory, mode: .multiProcess)
      let second = try makeStore(rootDirectory: rootDirectory, mode: .multiProcess)
      let changes = Changes()

      changes.track(first)
      second.suspend()

      #expect(changes.count == 1)
      #expect(first.isSuspended)
      second.resume()
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    @Test func `Writing A Value Is Not Observed`() throws {
      let store = try makeStore(mode: .multiProcess)
      let changes = Changes()

      changes.track(store)
      store.set("blob", forKey: "username")

      #expect(changes.count == 0)
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    @Test func `A Single Process Store Is Never Observed To Change`() throws {
      let store = try makeStore()
      let changes = Changes()

      changes.track(store)
      store.suspend()
      store.resume()

      #expect(changes.count == 0)
      #expect(!store.isSuspended)
    }
  }
#endif
