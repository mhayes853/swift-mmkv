#if Foundation && canImport(Darwin)
  import Foundation
  import SwiftMMKV
  import Testing

  #if canImport(SwiftUI)
    import SwiftUI
  #endif
  #if canImport(UIKit) && !os(watchOS)
    import UIKit
  #endif

  @MainActor
  @Suite(.requires(.store, .multiProcess)) struct MMKVSuspensionControllerTests {
    @Test func `A Manual Controller Suspends And Resumes Its Stores`() throws {
      let first = try makeStore(mode: .multiProcess)
      let second = try makeStore(mode: .multiProcess)
      let controller = MMKVSuspensionController(stores: [first, second])
      #expect(!first.isSuspended)

      controller.setActive(false)
      controller.setActive(false)
      #expect(first.isSuspended)
      #expect(second.isSuspended)

      controller.setActive(true)
      #expect(!first.isSuspended)
      #expect(!second.isSuspended)
    }

    @Test func `Takes Its Stores From Any Sequence`() throws {
      let first = try makeStore(mode: .multiProcess)
      let second = try makeStore(mode: .multiProcess)
      let stores = ["a": first, "b": second]
      let controller = MMKVSuspensionController(stores: stores.values)

      controller.setActive(false)
      #expect(first.isSuspended)
      #expect(second.isSuspended)
      controller.setActive(true)
      #expect(!first.isSuspended)
      #expect(!second.isSuspended)
    }

    #if canImport(SwiftUI)
      @Test func `The View Modifiers Take One Store Several Or A Sequence`() throws {
        let first = try makeStore(mode: .multiProcess)
        let second = try makeStore(mode: .multiProcess)
        // These only need to compile: each form resolves without ambiguity.
        _ = EmptyView().mmkvSuspension(first, isActive: true)
        _ = EmptyView().mmkvSuspension(first, second, isActive: true)
        _ = EmptyView().mmkvSuspension([first, second], isActive: true)
        _ = EmptyView().mmkvSuspension([first, second].lazy.filter { _ in true }, isActive: true)
        #if canImport(UIKit)
          _ = EmptyView().mmkvSuspension(first)
          _ = EmptyView().mmkvSuspension(first, second)
          _ = EmptyView().mmkvSuspension([first, second])
        #endif
      }
    #endif

    @Test func `An Invalidated Controller Leaves Its Stores As They Are`() throws {
      let store = try makeStore(mode: .multiProcess)
      let controller = MMKVSuspensionController(stores: [store])
      controller.setActive(false)

      controller.invalidate()
      controller.setActive(true)
      #expect(store.isSuspended)
      store.resume()
    }

    #if canImport(UIKit) && !os(watchOS)
      @Test func `Keeps The App Running While It Uses The Stores In The Background`() throws {
        let store = try makeStore(mode: .multiProcess)
        let center = NotificationCenter()
        let system = TestActivitySystem()
        let controller = MMKVSuspensionController(
          stores: [store],
          observing: .application,
          notificationCenter: center,
          activityLinger: .milliseconds(100),
          startActivity: { system.start($0, $1) }
        )
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        #expect(store.set("foreground", forKey: "key"))
        #expect(system.startCount == 0)

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(!store.isSuspended)
        #expect(store.set("background", forKey: "key"))
        #expect(store["key", as: String.self] == "background")
        #expect(system.startCount == 1)

        system.expire()
        #expect(store.isSuspended)
        system.waitUntilIdle()

        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        #expect(!store.isSuspended)
        #expect(store.set("foreground", forKey: "key"))
        #expect(system.startCount == 1)

        controller.invalidate()
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(store.set("invalidated", forKey: "key"))
        #expect(system.startCount == 1)
      }

      @Test func `Uses The Store In The Background Through The System's Activity`() throws {
        let store = try makeStore(mode: .multiProcess)
        let center = NotificationCenter()
        let controller = MMKVSuspensionController(
          stores: [store],
          observing: .application,
          notificationCenter: center
        )
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(store.set("value", forKey: "key"))
        #expect(store["key", as: String.self] == "value")
        #expect(!store.isSuspended)
        controller.invalidate()
      }

      @Test func `Stops Keeping The Application Running When It Is Released`() throws {
        let store = try makeStore(mode: .multiProcess)
        let center = NotificationCenter()
        let system = TestActivitySystem()
        var controller: MMKVSuspensionController? = MMKVSuspensionController(
          stores: [store],
          observing: .application,
          notificationCenter: center,
          startActivity: { system.start($0, $1) }
        )
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        _ = controller
        controller = nil

        #expect(store.set("value", forKey: "key"))
        #expect(system.startCount == 0)
      }

      @Test func `Stops Observing When It Is Released`() throws {
        let store = try makeStore(mode: .multiProcess)
        let center = NotificationCenter()
        var controller: MMKVSuspensionController? = MMKVSuspensionController(
          stores: [store],
          observing: .application,
          notificationCenter: center
        )
        _ = controller
        controller = nil

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(!store.isSuspended)
      }
    #endif
  }
#endif
