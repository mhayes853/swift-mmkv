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
      /// The stores stay usable in the background. Each operation that takes a file lock there
      /// keeps the app running until it finishes, so the app is never suspended holding the
      /// lock, and the stores are suspended only when the app's background time runs out.
      public static var application: Self { Self(kind: .application) }
    #endif
  }

  // MARK: - Controller

  /// Keeps an app from being suspended while its stores hold their file locks. See
  /// ``MMKVStore/suspend()``.
  ///
  /// Retain the controller for as long as it should observe the app:
  ///
  /// ```swift
  /// let suspension = MMKVSuspensionController(stores: [store], observing: .application)
  /// ```
  ///
  /// Observing the application, the controller leaves the stores usable in the background, and
  /// runs each operation that takes a file lock there inside an expiring activity, which keeps
  /// the app running until the operation finishes. Operations that follow one another closely
  /// share one activity, which ends about a second after the last of them. When the app's
  /// background time runs out, the controller suspends the stores, and it resumes them when the
  /// app returns to the foreground. An operation the system will not keep the app running for
  /// is turned away, as if the store were suspended.
  ///
  /// The controller leaves the stores as they are until its first lifecycle event. An app
  /// launched in the background never enters the background, so its operations are not kept
  /// running. Such an app ends its work by calling ``setActive(_:)`` with `false` itself.
  ///
  /// A manual controller suspends and resumes the stores when its owner calls ``setActive(_:)``.
  @MainActor
  public final class MMKVSuspensionController {
    private let stores: [MMKVStore]
    private let observation: Observation
    /// Keeps the app running while the stores hold their file locks in the background, if the
    /// controller observes the application.
    private let activity: ExpiringActivity?

    /// Starts observing `scope` on behalf of `stores`.
    ///
    /// - Parameters:
    ///   - stores: The stores to suspend and resume. Single-process stores are unaffected.
    ///   - scope: What to observe.
    ///   - notificationCenter: The center the lifecycle notifications are posted to. Pass
    ///     another to test lifecycle handling in isolation, posting on the main thread.
    public convenience init(
      stores: some Sequence<MMKVStore>,
      observing scope: MMKVSuspensionScope = .manual,
      notificationCenter: NotificationCenter = .default
    ) {
      self.init(
        stores: stores,
        observing: scope,
        notificationCenter: notificationCenter,
        startActivity: Self.startActivity
      )
    }

    /// - Parameter startActivity: Starts the activity that keeps the app running in the
    ///   background, or `nil` if the app needs none.
    package init(
      stores: some Sequence<MMKVStore>,
      observing scope: MMKVSuspensionScope = .manual,
      notificationCenter: NotificationCenter = .default,
      activityLinger: Duration = .seconds(1),
      startActivity: ExpiringActivity.Starter?
    ) {
      let stores = Array(stores)
      self.stores = stores
      self.observation = Observation(notificationCenter: notificationCenter)
      switch scope.kind {
      case .manual:
        self.activity = nil
      case .application:
        self.activity = startActivity.map { start in
          ExpiringActivity(linger: activityLinger, start: start) {
            for store in stores {
              store.suspend()
            }
          }
        }
        #if canImport(UIKit) && !os(watchOS)
          self.observe(UIApplication.didEnterBackgroundNotification) { $0.enterBackground() }
          self.observe(UIApplication.willEnterForegroundNotification) { $0.enterForeground() }
        #endif
      }
    }

    deinit {
      self.removeActivity()
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

    /// Stops observing, and stops ``setActive(_:)`` from having an effect. Operations stop
    /// keeping the app running, and the stores are otherwise left as they are.
    public func invalidate() {
      self.observation.invalidate()
      self.removeActivity()
    }

    private func enterBackground() {
      guard !self.observation.isInvalidated else { return }
      guard let activity = self.activity else {
        // Nothing can keep the app running, so it must not hold a lock from here on.
        return self.setActive(false)
      }
      for store in self.stores {
        store.setExpiringActivity(activity)
      }
    }

    private func enterForeground() {
      guard !self.observation.isInvalidated else { return }
      self.removeActivity()
      self.setActive(true)
    }

    private nonisolated func removeActivity() {
      guard let activity = self.activity else { return }
      for store in self.stores {
        store.removeExpiringActivity(activity)
      }
    }

    private func observe(
      _ name: Notification.Name,
      _ handler: @escaping @MainActor (MMKVSuspensionController) -> Void
    ) {
      self.observation.observe(name) { [weak self] in
        // Lifecycle notifications are posted on the main thread. They are handled before the
        // post returns, so the stores are ready before the app can be suspended.
        MainActor.assumeIsolated {
          if let self { handler(self) }
        }
      }
    }

    /// Starts an activity that keeps the app running, where the system offers one.
    private static var startActivity: ExpiringActivity.Starter? {
      #if (os(iOS) || os(tvOS) || os(visionOS)) && !targetEnvironment(macCatalyst)
        return { reason, block in
          ProcessInfo.processInfo.performExpiringActivity(withReason: reason, using: block)
        }
      #else
        return nil
      #endif
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
        self.mmkvSuspension(stores, isActive: isActive)
      }

      /// Suspends every store in `stores` whenever `isActive` is `false`, and resumes them
      /// when it is `true`. See ``MMKVStore/suspend()``.
      ///
      /// ```swift
      /// ContentView()
      ///   .mmkvSuspension(stores, isActive: scenePhase != .background)
      /// ```
      ///
      /// Apply this to a view that stays on screen for as long as the stores are in use.
      public func mmkvSuspension(
        _ stores: some Sequence<MMKVStore>,
        isActive: Bool
      ) -> some View {
        self.modifier(SuspensionModifier(stores: Array(stores), isActive: isActive))
      }
    }

    #if (canImport(UIKit) && !os(watchOS)) || os(watchOS)
      extension View {
        /// Keeps the app from being suspended while `stores` hold their file locks, as an
        /// ``MMKVSuspensionController`` observing the application does.
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
          self.mmkvSuspension(stores)
        }

        /// Keeps the app from being suspended while any store in `stores` holds its file lock,
        /// as an ``MMKVSuspensionController`` observing the application does.
        ///
        /// ```swift
        /// WindowGroup {
        ///   ContentView()
        ///     .mmkvSuspension(stores)
        /// }
        /// ```
        ///
        /// Apply this to a view that stays on screen for as long as the stores are in use.
        public func mmkvSuspension(_ stores: some Sequence<MMKVStore>) -> some View {
          self.modifier(SuspensionModifier(stores: Array(stores), isActive: nil))
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
