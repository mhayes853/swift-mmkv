package expo.modules.nativemmkv

import android.content.Context
import expo.modules.kotlin.exception.CodedException
import expo.modules.kotlin.exception.Exceptions
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.kotlin.records.Field
import expo.modules.kotlin.records.Record
import java.io.File

class StoreOptions : Record {
  @Field var id: String = "mmkv.default"
  @Field var encryptionKey: String? = null
}

/**
 * Exposes swift-mmkv to JavaScript, so the test app can compare what Swift sees in a store with
 * what react-native-mmkv sees in the same files.
 */
class NativeMMKVModule : Module() {
  private val handles = mutableMapOf<String, Long>()

  private val context: Context
    get() = appContext.reactContext ?: throw Exceptions.ReactContextLost()

  /** The directory react-native-mmkv keeps its stores in when its `path` option is not set. */
  private val rootDirectory: String
    get() = File(context.filesDir, "mmkv").path

  private fun open(options: StoreOptions): Long = synchronized(handles) {
    handles.getOrPut(options.id) {
      val handle = NativeBridge.open(
        rootDirectory.toByteArray(),
        options.id.toByteArray(),
        options.encryptionKey?.toByteArray()
      )
      if (handle < 0) {
        throw CodedException("ERR_OPEN", "Could not open the store ${options.id}.", null)
      }
      handle
    }
  }

  private fun split(joined: ByteArray): List<String> =
    if (joined.isEmpty()) emptyList() else joined.decodeToString().split('\u0000')

  override fun definition() = ModuleDefinition {
    Name("NativeMMKV")

    Function("rootDirectory") { rootDirectory }

    Function("setString") { store: StoreOptions, key: String, value: String ->
      NativeBridge.setString(open(store), key.toByteArray(), value.toByteArray())
    }
    Function("getString") { store: StoreOptions, key: String ->
      NativeBridge.getString(open(store), key.toByteArray())?.decodeToString()
    }

    Function("setNumber") { store: StoreOptions, key: String, value: Double ->
      NativeBridge.setNumber(open(store), key.toByteArray(), value)
    }
    Function("getNumber") { store: StoreOptions, key: String ->
      NativeBridge.getNumber(open(store), key.toByteArray()).firstOrNull()
    }

    Function("setBoolean") { store: StoreOptions, key: String, value: Boolean ->
      NativeBridge.setBoolean(open(store), key.toByteArray(), value)
    }
    Function("getBoolean") { store: StoreOptions, key: String ->
      when (NativeBridge.getBoolean(open(store), key.toByteArray())) {
        1 -> true
        0 -> false
        else -> null
      }
    }

    Function("setBytes") { store: StoreOptions, key: String, value: List<Int> ->
      val bytes = ByteArray(value.size) { value[it].toByte() }
      NativeBridge.setBytes(open(store), key.toByteArray(), bytes)
    }
    Function("getBytes") { store: StoreOptions, key: String ->
      NativeBridge.getBytes(open(store), key.toByteArray())?.map { it.toInt() and 0xFF }
    }

    Function("keys") { store: StoreOptions -> split(NativeBridge.keys(open(store))) }
    Function("remove") { store: StoreOptions, key: String ->
      NativeBridge.remove(open(store), key.toByteArray())
    }
    Function("removeAll") { store: StoreOptions -> NativeBridge.removeAll(open(store)) }

    Function("increment") { store: StoreOptions, key: String ->
      NativeBridge.increment(open(store), key.toByteArray())
    }

    Function("checkForExternalChanges") { store: StoreOptions ->
      NativeBridge.checkForExternalChanges(open(store))
    }
    Function("changes") { store: StoreOptions -> split(NativeBridge.changes(open(store))) }

    // Leaves the outcome where the script that launched the app can read it.
    Function("writeResults") { json: String ->
      File(context.getExternalFilesDir(null), "e2e-results.json").writeText(json)
    }
  }
}
