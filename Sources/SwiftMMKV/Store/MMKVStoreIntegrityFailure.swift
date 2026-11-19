// MARK: - Integrity Failures

extension MMKVStore {
  /// A store's file failing its integrity check as it was loaded, which can happen after the
  /// process is killed in the middle of a write.
  ///
  /// What becomes of the file's contents is decided by the store's
  /// ``MMKVConfiguration/recovery``.
  public struct IntegrityFailure: Sendable, Hashable {
    /// The check a file failed.
    public enum Kind: Sendable, Hashable {
      /// The file's contents do not match their checksum.
      case checksum

      /// The file is not as long as it records itself to be.
      case fileLength
    }

    /// The identifier of the store whose file failed the check.
    ///
    /// MMKV reports the identifier alone, so stores with the same identifier in different
    /// directories cannot be told apart.
    public let id: MMKVStore.ID

    /// The check the file failed.
    public let kind: Kind

    /// Creates a failure.
    public init(id: MMKVStore.ID, kind: Kind) {
      self.id = id
      self.kind = kind
    }
  }

  /// Calls `onFailure` whenever the file of any store in this process fails its integrity
  /// check, until the returned subscription is cancelled or released.
  ///
  /// ```swift
  /// let subscription = MMKVStore.subscribeToIntegrityFailures { failure in
  ///   analytics.record("mmkv_corruption", store: failure.id.rawValue)
  /// }
  /// ```
  ///
  /// A file is checked when its store first reads or writes it, which is after the store is
  /// opened, and again whenever the store reloads it after another process changed it.
  /// Subscribe before using the stores to be told about.
  ///
  /// The listener runs on the thread that was loading the file, while MMKV holds the store's
  /// lock. It must not read or write a store.
  ///
  /// - Parameter onFailure: Runs with each failure.
  public static func subscribeToIntegrityFailures(
    _ onFailure: @escaping @Sendable (IntegrityFailure) -> Void
  ) -> MMKVSubscription {
    IntegrityFailureListeners.add(onFailure)
  }
}
