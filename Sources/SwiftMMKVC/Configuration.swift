import CSwiftMMKV
import SwiftMMKV

/// The object behind a `swiftmmkv_configuration`.
///
/// The setters return nothing, so an option that was set to a value this version does not know
/// is remembered here and reported when a store is opened.
final class Configuration {
  var value: MMKVConfiguration
  var hasInvalidMode = false
  var hasInvalidEncryption = false
  var hasInvalidRecovery = false

  init(_ value: MMKVConfiguration) {
    self.value = value
  }

  var hasInvalidArgument: Bool {
    self.hasInvalidMode || self.hasInvalidEncryption || self.hasInvalidRecovery
  }

  func setMode(_ mode: swiftmmkv_mode) {
    switch Int(mode) {
    case Int(SWIFTMMKV_MODE_SINGLE_PROCESS): self.value.mode = .singleProcess
    case Int(SWIFTMMKV_MODE_MULTI_PROCESS): self.value.mode = .multiProcess
    default:
      self.hasInvalidMode = true
      return
    }
    self.hasInvalidMode = false
  }
}

/// The cipher and key of a C call, or `nil` if `encryption` is not one of its constants.
///
/// A key of the wrong length is let through, for the store to turn down.
func makeEncryption(
  _ encryption: swiftmmkv_encryption,
  _ key: UnsafeRawPointer?,
  _ keyCount: Int
) -> MMKVConfiguration.Encryption?? {
  switch Int(encryption) {
  case Int(SWIFTMMKV_ENCRYPTION_NONE): .some(nil)
  case Int(SWIFTMMKV_ENCRYPTION_AES128): .aes128(key: makeBytes(key, keyCount))
  case Int(SWIFTMMKV_ENCRYPTION_AES256): .aes256(key: makeBytes(key, keyCount))
  default: nil
  }
}

@c @implementation
public func swiftmmkv_configuration_create(
  _ directory: UnsafePointer<CChar>,
  _ mode: swiftmmkv_mode
) -> OpaquePointer {
  let configuration = Configuration(
    MMKVConfiguration(
      directory: MMKVDirectory(path: String(cString: directory)),
      mode: .singleProcess
    )
  )
  configuration.setMode(mode)
  return OpaquePointer(retaining: configuration)
}

@c @implementation
public func swiftmmkv_configuration_create_temporary() -> OpaquePointer {
  OpaquePointer(retaining: Configuration(.temporary()))
}

@c @implementation
public func swiftmmkv_configuration_destroy(_ configuration: OpaquePointer?) {
  configuration?.release(as: Configuration.self)
}

@c @implementation
public func swiftmmkv_configuration_set_id(
  _ configuration: OpaquePointer,
  _ id: UnsafePointer<CChar>
) {
  configuration.object(Configuration.self).value.id = MMKVStore.ID(rawValue: String(cString: id))
}

@c @implementation
public func swiftmmkv_configuration_set_directory(
  _ configuration: OpaquePointer,
  _ directory: UnsafePointer<CChar>
) {
  configuration.object(Configuration.self).value.directory = MMKVDirectory(
    path: String(cString: directory)
  )
}

@c @implementation
public func swiftmmkv_configuration_set_mode(_ configuration: OpaquePointer, _ mode: swiftmmkv_mode)
{
  configuration.object(Configuration.self).setMode(mode)
}

@c @implementation
public func swiftmmkv_configuration_set_read_only(_ configuration: OpaquePointer, _ readOnly: Bool)
{
  configuration.object(Configuration.self).value.isReadOnly = readOnly
}

@c @implementation
public func swiftmmkv_configuration_set_encryption(
  _ configuration: OpaquePointer,
  _ encryption: swiftmmkv_encryption,
  _ key: UnsafeRawPointer?,
  _ keyCount: Int
) {
  let configuration = configuration.object(Configuration.self)
  guard let encryption = makeEncryption(encryption, key, keyCount) else {
    configuration.hasInvalidEncryption = true
    return
  }
  configuration.value.encryption = encryption
  configuration.hasInvalidEncryption = false
}

@c @implementation
public func swiftmmkv_configuration_set_expected_capacity(
  _ configuration: OpaquePointer,
  _ bytes: Int
) {
  configuration.object(Configuration.self).value.expectedCapacity = bytes
}

@c @implementation
public func swiftmmkv_configuration_set_recovery(
  _ configuration: OpaquePointer,
  _ recovery: swiftmmkv_recovery
) {
  let configuration = configuration.object(Configuration.self)
  switch Int(recovery) {
  case Int(SWIFTMMKV_RECOVERY_DISCARD): configuration.value.recovery = .discard
  case Int(SWIFTMMKV_RECOVERY_RECOVER): configuration.value.recovery = .recover
  default:
    configuration.hasInvalidRecovery = true
    return
  }
  configuration.hasInvalidRecovery = false
}

@c @implementation
public func swiftmmkv_configuration_set_compare_before_set(
  _ configuration: OpaquePointer,
  _ enabled: Bool
) {
  configuration.object(Configuration.self).value.compareBeforeSet = enabled
}

@c @implementation
public func swiftmmkv_configuration_set_item_size_limit(
  _ configuration: OpaquePointer,
  _ bytes: Int
) {
  configuration.object(Configuration.self).value.itemSizeLimit = bytes == 0 ? nil : bytes
}
