/// An error from opening or re-encrypting an ``MMKVStore``.
public enum MMKVError: Error, Sendable, Hashable {
  /// The store could not be opened, for example because its identifier or root directory is
  /// empty.
  case openFailed(id: String, rootDirectory: String)

  /// The encryption key is empty or longer than its cipher allows.
  case invalidEncryptionKey

  /// The store could not be re-encrypted, for example because it is read-only.
  case rekeyFailed

  /// The app group named by the `AppGroupIdentifier` key of the app's `Info.plist` has no
  /// container this process can reach.
  case appGroupContainerUnavailable(identifier: String)
}
