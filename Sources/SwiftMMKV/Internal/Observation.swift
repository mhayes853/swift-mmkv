#if canImport(Observation)
  import Observation
#endif

// MARK: - _Observable

/// `Observable` where the platform has the Observation framework, so that a type can conform
/// without checking for the framework itself.
#if canImport(Observation)
  @available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
  protocol _Observable: Observable {}
#else
  @available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *)
  protocol _Observable {}
#endif

// MARK: - _ObservationRegistrar

/// An `ObservationRegistrar` that a type can store whichever OS it runs on.
///
/// `ObservationRegistrar` needs a newer OS than this package supports, so a stored property
/// cannot name it. This does nothing on an older OS, and where there is no Observation
/// framework.
struct _ObservationRegistrar: Sendable {
  #if canImport(Observation)
    private let registrar: (any Sendable)?
  #endif

  init() {
    #if canImport(Observation)
      if #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *) {
        self.registrar = ObservationRegistrar()
      } else {
        self.registrar = nil
      }
    #endif
  }

  func access<Subject, Member>(_ subject: Subject, keyPath: KeyPath<Subject, Member>) {
    #if canImport(Observation)
      guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *) else { return }
      func open<S: _Observable>(_ subject: S) {
        (self.registrar as! ObservationRegistrar)
          .access(subject, keyPath: unsafeDowncast(keyPath, to: KeyPath<S, Member>.self))
      }
      guard let subject = subject as? any _Observable else { return }
      open(subject)
    #endif
  }

  func withMutation<Subject, Member, T>(
    of subject: Subject,
    keyPath: KeyPath<Subject, Member>,
    _ mutation: () throws -> T
  ) rethrows -> T {
    #if canImport(Observation)
      guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, *) else {
        return try mutation()
      }
      func open<S: _Observable>(_ subject: S, _ mutation: () throws -> T) rethrows -> T {
        try (self.registrar as! ObservationRegistrar)
          .withMutation(
            of: subject,
            keyPath: unsafeDowncast(keyPath, to: KeyPath<S, Member>.self),
            mutation
          )
      }
      guard let subject = subject as? any _Observable else { return try mutation() }
      return try open(subject, mutation)
    #else
      return try mutation()
    #endif
  }
}
