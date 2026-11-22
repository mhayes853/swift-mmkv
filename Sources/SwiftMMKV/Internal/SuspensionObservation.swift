#if canImport(Observation)
  import Observation

  /// Tells the Observation framework when a store is suspended and resumed.
  ///
  /// It stands in for the store as the subject that is observed, so that ``MMKVStore`` does not
  /// have to be `Observable`, which would suggest that its values are tracked too.
  @available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
  final class SuspensionObservation: Observable, Sendable {
    private let registrar = ObservationRegistrar()

    /// The property that is observed. It has no value of its own, because the gate holds the
    /// state.
    private var isSuspended: Void { () }

    func access() {
      self.registrar.access(self, keyPath: \.isSuspended)
    }

    func withMutation<R>(_ mutation: () -> R) -> R {
      self.registrar.withMutation(of: self, keyPath: \.isSuspended, mutation)
    }
  }
#endif

extension MMKVStoreState {
  /// The observation of a new state, where the platform has the Observation framework.
  static func makeSuspensionObservation() -> (any Sendable)? {
    #if canImport(Observation)
      if #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *) {
        return SuspensionObservation()
      }
    #endif
    return nil
  }

  /// Records that whatever is being observed read whether the store is suspended.
  func accessSuspension() {
    #if canImport(Observation)
      if #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *) {
        (self.suspensionObservation as? SuspensionObservation)?.access()
      }
    #endif
  }

  /// Runs `mutation`, which suspends or resumes the store, and tells its observers.
  func withSuspensionMutation<R>(_ mutation: () -> R) -> R {
    #if canImport(Observation)
      if #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *),
        let observation = self.suspensionObservation as? SuspensionObservation
      {
        return observation.withMutation(mutation)
      }
    #endif
    return mutation()
  }
}
