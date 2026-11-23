import CSwiftMMKV
import SwiftMMKV

private func makeDirectory(_ path: UnsafePointer<CChar>) -> MMKVDirectory {
  MMKVDirectory(path: String(cString: path))
}

private func makeID(_ id: UnsafePointer<CChar>) -> MMKVStore.ID {
  MMKVStore.ID(rawValue: String(cString: id))
}

@c @implementation
public func swiftmmkv_directory_contains_store(
  _ directory: UnsafePointer<CChar>,
  _ id: UnsafePointer<CChar>
) -> Bool {
  makeDirectory(directory).containsStore(id: makeID(id))
}

@c @implementation
public func swiftmmkv_directory_is_store_valid(
  _ directory: UnsafePointer<CChar>,
  _ id: UnsafePointer<CChar>
) -> Bool {
  makeDirectory(directory).isStoreValid(id: makeID(id))
}

@c @implementation
public func swiftmmkv_directory_remove_store(
  _ directory: UnsafePointer<CChar>,
  _ id: UnsafePointer<CChar>,
  _ outRemoved: UnsafeMutablePointer<Bool>?
) -> swiftmmkv_status {
  status { () throws(MMKVError) in
    let didRemove = try makeDirectory(directory).removeStore(id: makeID(id))
    outRemoved?.pointee = didRemove
  }
}

@c @implementation
public func swiftmmkv_directory_remove_all_stores(
  _ directory: UnsafePointer<CChar>,
  _ outCount: UnsafeMutablePointer<Int>?
) -> swiftmmkv_status {
  status { () throws(MMKVError) in
    let count = try makeDirectory(directory).removeAllStores()
    outCount?.pointee = count
  }
}

@c @implementation
public func swiftmmkv_directory_back_up_store(
  _ directory: UnsafePointer<CChar>,
  _ id: UnsafePointer<CChar>,
  _ backup: UnsafePointer<CChar>,
  _ outBackedUp: UnsafeMutablePointer<Bool>?
) -> swiftmmkv_status {
  status { () throws(MMKVError) in
    let didBackUp = try makeDirectory(directory)
      .backUpStore(
        id: makeID(id),
        to: makeDirectory(backup)
      )
    outBackedUp?.pointee = didBackUp
  }
}

@c @implementation
public func swiftmmkv_directory_back_up_all_stores(
  _ directory: UnsafePointer<CChar>,
  _ backup: UnsafePointer<CChar>,
  _ outCount: UnsafeMutablePointer<Int>?
) -> swiftmmkv_status {
  status { () throws(MMKVError) in
    let count = try makeDirectory(directory).backUpAllStores(to: makeDirectory(backup))
    outCount?.pointee = count
  }
}

@c @implementation
public func swiftmmkv_directory_restore_store(
  _ directory: UnsafePointer<CChar>,
  _ id: UnsafePointer<CChar>,
  _ backup: UnsafePointer<CChar>,
  _ outRestored: UnsafeMutablePointer<Bool>?
) -> swiftmmkv_status {
  status { () throws(MMKVError) in
    let didRestore = try makeDirectory(directory)
      .restoreStore(
        id: makeID(id),
        from: makeDirectory(backup)
      )
    outRestored?.pointee = didRestore
  }
}

@c @implementation
public func swiftmmkv_directory_restore_all_stores(
  _ directory: UnsafePointer<CChar>,
  _ backup: UnsafePointer<CChar>,
  _ outCount: UnsafeMutablePointer<Int>?
) -> swiftmmkv_status {
  status { () throws(MMKVError) in
    let count = try makeDirectory(directory).restoreAllStores(from: makeDirectory(backup))
    outCount?.pointee = count
  }
}
