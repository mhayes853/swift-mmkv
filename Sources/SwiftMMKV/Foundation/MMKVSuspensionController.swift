#if Foundation && canImport(Darwin)
  import _SwiftMMKVFoundation

  #if canImport(UIKit) && !os(watchOS)
    import UIKit
  #endif
  #if canImport(SwiftUI)
    import SwiftUI
  #endif

  // MARK: - Scope

  /// Selects what an ``MMKVSuspensionController`` observes to learn that its app is about to
  /// stop running.
  public struct MMKVSuspensionScope: Sendable {
    fileprivate enum Kind: Sendable {
      case manual
      case application
    }

    fileprivate let kind: Kind

    /// The owner calls ``MMKVSuspensionController/setActive(_:)`` as its lifecycle changes.
    public static var manual: Self { Self(kind: .manual) }

    #if canImport(UIKit) && !os(watchOS)
      /// Observes the UIKit application entering the background and returning to the
      /// foreground.
      ///
      /// The stores stay usable while the app is merely inactive, as it is under the app
      /// switcher or an incoming call, because a suspended store turns reads away too.
      public static var application: Self { Self(kind: .application) }
    #endif
  }

  // MARK: - Controller

  /// Suspends stores when their app is about to stop running, and resumes them when it runs
  /// again. See ``MMKVStore/suspend()``.
  ///
  /// Retain the controller for as long as it should observe the app:
  ///
  /// ```swift
  /// let suspension = MMKVSuspensionController(stores: [store], observing: .application)
  /// ```
  ///
  /// The controller leaves the stores as they are until its first lifecycle event, so an app
  /// launched in the background can use them. Such an app never enters the background, and
  /// ends its work by calling ``setActive(_:)`` with `false` itself.
  ///
  /// A store suspended on entering the background turns away anything the app does afterwards,
  /// including writes made by the app's own handling of that event. Save state before then, or
  /// drive the controller manually and suspend once that work is done.
  @MainActor
  public final class MMKVSuspensionController {
    private let stores: [MMKVStore]
    private let observation: Observation

    /// Starts observing `scope` on behalf of `stores`.
    ///
    /// - Parameters:
    ///   - stores: The stores to suspend and resume. Single-process stores are unaffected.
    ///   - scope: What to observe.
    ///   - notificationCenter: The center the lifecycle notifications are posted to. Pass
    ///     another to test lifecycle handling in isolation, posting on the main thread.
    public init(
      stores: [MMKVStore],
      observing scope: MMKVSuspensionScope = .manual,
      notificationCenter: NotificationCenter = .default
    ) {
      self.stores = stores
      self.observation = Observation(notificationCenter: notificationCenter)
      switch scope.kind {
      case .manual:
        break
      case .application:
        #if canImport(UIKit) && !os(watchOS)
          self.observe(UIApplication.didEnterBackgroundNotification, isActive: false)
          self.observe(UIApplication.willEnterForegroundNotification, isActive: true)
        #endif
      }
    }

    /// Resumes the stores if `isActive`, and suspends them otherwise. Calling this again with
    /// the same value has no further effect.
    public func setActive(_ isActive: Bool) {
      guard !self.observation.isInvalidated else { return }
      for store in self.stores {
        if isActive {
          store.resume()
        } else {
          store.suspend()
        }
      }
    }

    /// Stops observing, and stops ``setActive(_:)`` from having an effect. The stores stay as
    /// they are.
    public func invalidate() {
      self.observation.invalidate()
    }

    private func observe(_ name: Notification.Name, isActive: Bool) {
      self.observation.observe(name) { [weak self] in
        // Lifecycle notifications are posted on the main thread. They are handled before the
        // post returns, so the stores are suspended before the app can be.
        MainActor.assumeIsolated { self?.setActive(isActive) }
      }
    }
  }

  /// The notification observers of a controller, which are removed when the controller is
  /// invalidated or released.
  private final class Observation: Sendable {
    /// A token from `NotificationCenter`, which is only ever handed back to it.
    private struct Observer: @unchecked Sendable {
      let token: any NSObjectProtocol
    }

    private struct State {
      var observers = [Observer]()
      var isInvalidated = false
    }

    private let notificationCenter: NotificationCenter
    private let state = Lock(State())

    init(notificationCenter: NotificationCenter) {
      self.notificationCenter = notificationCenter
    }

    deinit {
      self.invalidate()
    }

    var isInvalidated: Bool {
      self.state.withLock { $0.isInvalidated }
    }

    func observe(_ name: Notification.Name, _ handler: @escaping @Sendable () -> Void) {
      let observer = Observer(
        token: self.notificationCenter.addObserver(forName: name, object: nil, queue: nil) { _ in
          handler()
        }
      )
      self.state.withLock { $0.observers.append(observer) }
    }

    func invalidate() {
      let observers = self.state.withLock { state in
        state.isInvalidated = true
        defer { state.observers.removeAll() }
        return state.observers
      }
      for observer in observers {
        self.notificationCenter.removeObserver(observer.token)
      }
    }
  }

  // MARK: - SwiftUI

  #if canImport(SwiftUI)
    extension View {
      /// Suspends `stores` whenever `isActive` is `false`, and resumes them when it is `true`.
      /// See ``MMKVStore/suspend()``.
      ///
      /// ```swift
      /// ContentView()
      ///   .mmkvSuspension(store, isActive: scenePhase != .background)
      /// ```
      ///
      /// Apply this to a view that stays on screen for as long as the stores are in use.
      public func mmkvSuspension(_ stores: MMKVStore..., isActive: Bool) -> some View {
        self.modifier(SuspensionModifier(stores: stores, isActive: isActive))
      }
    }

    #if (canImport(UIKit) && !os(watchOS)) || os(watchOS)
      extension View {
        /// Suspends `stores` when the app enters the background, and resumes them when it
        /// returns to the foreground. See ``MMKVStore/suspend()``.
        ///
        /// ```swift
        /// WindowGroup {
        ///   ContentView()
        ///     .mmkvSuspension(store)
        /// }
        /// ```
        ///
        /// Apply this to a view that stays on screen for as long as the stores are in use.
        public func mmkvSuspension(_ stores: MMKVStore...) -> some View {
          self.modifier(SuspensionModifier(stores: stores, isActive: nil))
        }
      }
    #endif

    private struct SuspensionModifier: ViewModifier {
      let stores: [MMKVStore]
      /// `nil` to follow the app's lifecycle instead of a value the view supplies.
      let isActive: Bool?
      @State private var controller: MMKVSuspensionController?
      @Environment(\.scenePhase) private var scenePhase

      func body(content: Content) -> some View {
        content
          .onAppear { self.start() }
          .onChange(of: self.stores.map(ObjectIdentifier.init)) { _ in self.start() }
          .onChange(of: self.suppliedIsActive) { isActive in
            if let isActive { self.controller?.setActive(isActive) }
          }
          .onDisappear {
            self.controller?.invalidate()
            self.controller = nil
          }
      }

      /// Whether the stores should be active, where that is not left to a controller that
      /// observes the application. watchOS has no application notifications to observe, so its
      /// scene phase stands in for them.
      private var suppliedIsActive: Bool? {
        #if os(watchOS)
          self.isActive ?? (self.scenePhase != .background)
        #else
          self.isActive
        #endif
      }

      private func start() {
        self.controller?.invalidate()
        #if canImport(UIKit) && !os(watchOS)
          let scope: MMKVSuspensionScope = self.isActive == nil ? .application : .manual
        #else
          let scope = MMKVSuspensionScope.manual
        #endif
        let controller = MMKVSuspensionController(stores: self.stores, observing: scope)
        if let isActive = self.isActive {
          controller.setActive(isActive)
        }
        self.controller = controller
      }
    }
  #endif
#endif
