package expo.modules.nativemmkv

/**
 * The Swift functions in `swift/Sources/NativeMMKVBridge`. Strings cross as UTF-8 byte arrays,
 * because JNI's own string functions use a modified UTF-8 that mangles emoji.
 */
internal object NativeBridge {
  init {
    System.loadLibrary("NativeMMKVBridge")
  }

  /** Returns a handle for the other functions, or -1 if the store could not be opened. */
  @JvmStatic external fun open(rootDirectory: ByteArray, id: ByteArray, encryptionKey: ByteArray?): Long

  @JvmStatic external fun setString(handle: Long, key: ByteArray, value: ByteArray): Boolean
  @JvmStatic external fun getString(handle: Long, key: ByteArray): ByteArray?

  @JvmStatic external fun setNumber(handle: Long, key: ByteArray, value: Double): Boolean
  /** Returns an array holding the number, or an empty array if the key has no value. */
  @JvmStatic external fun getNumber(handle: Long, key: ByteArray): DoubleArray

  @JvmStatic external fun setBoolean(handle: Long, key: ByteArray, value: Boolean): Boolean
  /** Returns 1 or 0, or -1 if the key has no value. */
  @JvmStatic external fun getBoolean(handle: Long, key: ByteArray): Int

  @JvmStatic external fun setBytes(handle: Long, key: ByteArray, value: ByteArray): Boolean
  @JvmStatic external fun getBytes(handle: Long, key: ByteArray): ByteArray?

  /** Returns the keys, sorted and separated by NUL bytes. */
  @JvmStatic external fun keys(handle: Long): ByteArray
  @JvmStatic external fun remove(handle: Long, key: ByteArray): Boolean
  @JvmStatic external fun removeAll(handle: Long)

  @JvmStatic external fun increment(handle: Long, key: ByteArray): Double

  @JvmStatic external fun checkForExternalChanges(handle: Long)
  /** Returns the changes the store has reported, separated by NUL bytes. */
  @JvmStatic external fun changes(handle: Long): ByteArray
}
