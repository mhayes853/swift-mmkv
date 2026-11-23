import CSwiftMMKV
import SwiftMMKV

// MARK: - Logging

@c @implementation
public func swiftmmkv_log_minimum_level() -> swiftmmkv_log_level {
  guard let level = MMKVLog.minimumLevel else { return swiftmmkv_log_level(SWIFTMMKV_LOG_NONE) }
  return swiftmmkv_log_level(level.rawValue)
}

@c @implementation
public func swiftmmkv_log_set_minimum_level(_ level: swiftmmkv_log_level) {
  if Int(level) == Int(SWIFTMMKV_LOG_NONE) {
    MMKVLog.minimumLevel = nil
  } else if let level = MMKVLog.Level(rawValue: Int(level)) {
    MMKVLog.minimumLevel = level
  }
}

@c @implementation
public func swiftmmkv_log_set_handler(
  _ context: UnsafeMutableRawPointer?,
  _ handler: swiftmmkv_log_callback?,
  _ release: swiftmmkv_context_release?
) {
  // Without a handler nothing holds on to the context, which releases it straight away.
  let context = CallbackContext(context, release: release)
  guard let handler else {
    MMKVLog.setHandler(nil)
    return
  }
  MMKVLog.setHandler { message in
    message.text.withCString { text in
      message.file.withCString { file in
        message.function.withCString { function in
          handler(
            context.pointer,
            swiftmmkv_log_level(message.level.rawValue),
            text,
            file,
            function,
            Int32(clamping: message.line)
          )
        }
      }
    }
  }
}

// MARK: - Integrity Failures

@c @implementation
public func swiftmmkv_subscribe_to_integrity_failures(
  _ context: UnsafeMutableRawPointer?,
  _ onFailure: swiftmmkv_integrity_failure_callback,
  _ release: swiftmmkv_context_release?
) -> OpaquePointer {
  let context = CallbackContext(context, release: release)
  let subscription = MMKVStore.subscribeToIntegrityFailures { failure in
    let kind =
      switch failure.kind {
      case .checksum: SWIFTMMKV_INTEGRITY_FAILURE_CHECKSUM
      case .fileLength: SWIFTMMKV_INTEGRITY_FAILURE_FILE_LENGTH
      }
    failure.id.rawValue.withCString {
      onFailure(context.pointer, $0, swiftmmkv_integrity_failure_kind(kind))
    }
  }
  return OpaquePointer(retaining: Subscription(subscription))
}
