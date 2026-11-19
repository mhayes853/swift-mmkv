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
      @Test func `Follows The Application Entering And Leaving The Background`() throws {
        let store = try makeStore(mode: .multiProcess)
        let center = NotificationCenter()
        let controller = MMKVSuspensionController(
          stores: [store],
          observing: .application,
          notificationCenter: center
        )
        #expect(!store.isSuspended)

        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        #expect(!store.isSuspended)

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(store.isSuspended)

        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        #expect(!store.isSuspended)

        controller.invalidate()
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        #expect(!store.isSuspended)
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
