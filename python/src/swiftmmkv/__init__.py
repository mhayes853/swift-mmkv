"""Python bindings for swift-mmkv, a wrapper around the core of MMKV, Tencent's
memory-mapped key-value store.

::

    import swiftmmkv
    from swiftmmkv import Mode

    with swiftmmkv.open("/var/lib/app/mmkv", mode=Mode.SINGLE_PROCESS) as store:
        store.set("username", "blob")
        store.set("volume", 0.8)

        store.get("username", str)             # "blob"
        store.get("volume", float, default=1)  # 0.8

A store's file records no types, so a value is read by naming the type it was written with.
`Store` is where to start reading.
"""

from ._changes import ChangeBatch, Subscription
from ._configuration import (
    Cipher,
    Configuration,
    Encryption,
    Expiry,
    ExpiryLike,
    FileProtection,
    Mode,
    Recovery,
    StoreID,
)
from ._converters import (
    JSON,
    Converter,
    Reader,
    TypeSpec,
    Writer,
    bytes_converter,
    float32,
    float64,
    int32,
    int64,
    number,
    text_converter,
    uint32,
    uint64,
)
from ._directory import Directory
from ._errors import MMKVError, Status
from ._keys import DefaultedKey, Fields, HasStore, Key
from ._logging import (
    IntegrityFailure,
    IntegrityFailureKind,
    LogLevel,
    LogMessage,
    log_level,
    logger,
    on_integrity_failure,
    set_log_handler,
    set_log_level,
)
from ._logging import (
    install as _install_logging,
)
from ._store import Plain, Store, open, open_temporary

__all__ = [
    "JSON",
    "ChangeBatch",
    "Cipher",
    "Configuration",
    "Converter",
    "DefaultedKey",
    "Directory",
    "Encryption",
    "Expiry",
    "ExpiryLike",
    "Fields",
    "FileProtection",
    "HasStore",
    "IntegrityFailure",
    "IntegrityFailureKind",
    "Key",
    "LogLevel",
    "LogMessage",
    "MMKVError",
    "Mode",
    "Plain",
    "Reader",
    "Recovery",
    "Status",
    "Store",
    "StoreID",
    "Subscription",
    "TypeSpec",
    "Writer",
    "bytes_converter",
    "float32",
    "float64",
    "int32",
    "int64",
    "log_level",
    "logger",
    "number",
    "on_integrity_failure",
    "open",
    "open_temporary",
    "set_log_handler",
    "set_log_level",
    "text_converter",
    "uint32",
    "uint64",
]

# MMKV's messages go to the `logging` module from the moment the package is imported.
_install_logging()
del _install_logging
