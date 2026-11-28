// Lets the C++ core, which does not know which stores this core has open, copy an open store's
// files out to a backup or overwrite them from one. It treats the store as closed, so it takes
// the file lock on a descriptor of its own, which excludes other processes.

extension StoreInstance {
  /// Runs `body`, which reads or overwrites the files of `instances` by their paths, while no
  /// thread of this process is using those instances.
  ///
  /// The instances' own file locks are given up meanwhile, because `body` takes them on other
  /// descriptors, which a lock held here would block for good.
  ///
  /// - Parameter reloading: Whether `body` overwrites the files, so that the instances must load
  ///   them again.
  package static func withFilesHandedOver<R>(
    _ instances: [StoreInstance],
    reloading: Bool,
    _ body: () -> R
  ) -> R {
    Self.lockAll(instances)
    for instance in instances {
      instance.state.withLock { $0.exclusiveProcessLock.suspendFileLock() }
    }
    defer {
      for instance in instances {
        instance.state.withLock { state in
          if reloading {
            state.clearMemoryCache()
            // An instance that has not loaded yet skips that, but may have mapped the file.
            state.file.clearMemoryCache()
          }
          state.exclusiveProcessLock.resumeFileLock()
        }
        instance.state.unlock()
      }
    }
    return body()
  }

  /// Takes every instance's lock. Another thread may hold one of them while it waits for
  /// another, as an import does, so only one lock is ever waited for while none is held.
  private static func lockAll(_ instances: [StoreInstance]) {
    guard !instances.isEmpty else { return }
    var awaited = 0
    while true {
      instances[awaited].state.lock()
      var taken = [awaited]
      for index in instances.indices where index != awaited {
        guard instances[index].state.tryLock() else { break }
        taken.append(index)
      }
      if taken.count == instances.count {
        return
      }
      for index in taken {
        instances[index].state.unlock()
      }
      awaited = instances.indices.first { !taken.contains($0) }!
    }
  }
}

extension StoreInstance {
  /// Unmaps and closes the instance's files, for an instance that is never used again.
  func releaseFiles() {
    self.state.withLock { state in
      state.contentChangedHandler = nil
      state.tracksChangedKeys = false
      state.changeTracker = nil
      state.clearMemoryCache()
      // An instance that has not loaded yet skips that, but may have mapped the file.
      state.file.clearMemoryCache()
      state.metaFile.clearMemoryCache()
    }
  }
}
