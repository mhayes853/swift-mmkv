"""Where MMKV's log messages go, and who hears of a file that fails its integrity check."""

from __future__ import annotations

import atexit
import enum
import logging
from collections.abc import Callable
from dataclasses import dataclass
from typing import Final

from . import _changes, _raw
from ._changes import Subscription
from ._configuration import StoreID


class LogLevel(enum.IntEnum):
    """How severe a message MMKV logged is."""

    #: What MMKV is doing, such as loading a file or growing one.
    INFO = _raw.SWIFTMMKV_LOG_INFO
    #: Something unexpected that MMKV carried on from.
    WARNING = _raw.SWIFTMMKV_LOG_WARNING
    #: A failure, such as a file that cannot be opened or that fails its integrity check.
    ERROR = _raw.SWIFTMMKV_LOG_ERROR
    #: As a minimum level, logs nothing. No message has this level.
    NONE = _raw.SWIFTMMKV_LOG_NONE


@dataclass(frozen=True, slots=True)
class LogMessage:
    """A message MMKV logged, with the MMKV source file, function and line that logged it."""

    level: LogLevel
    text: str
    file: str
    function: str
    line: int


#: Where MMKV's messages go unless `set_log_handler` says otherwise: the logger named
#: `swiftmmkv`. A record has the level of its message, and the MMKV source file, function
#: and line as its `pathname`, `funcName` and `lineno`.
logger: Final = logging.getLogger("swiftmmkv")

_LOGGING_LEVELS: Final = {
    _raw.SWIFTMMKV_LOG_INFO: logging.INFO,
    _raw.SWIFTMMKV_LOG_WARNING: logging.WARNING,
    _raw.SWIFTMMKV_LOG_ERROR: logging.ERROR,
}

_handler: Callable[[LogMessage], object] | None = None


def _log(
    context: int | None, level: int, text: bytes, file: bytes, function: bytes, line: int
) -> None:
    # An error that is raised here does not cross into the library: `ctypes` hands it to
    # `sys.unraisablehook`.
    handler = _handler
    if handler is not None:
        handler(
            LogMessage(
                LogLevel(level),
                text.decode("utf-8", "replace"),
                file.decode("utf-8", "replace"),
                function.decode("utf-8", "replace"),
                line,
            )
        )
        return
    logging_level = _LOGGING_LEVELS.get(level, logging.WARNING)
    if logger.isEnabledFor(logging_level):
        logger.handle(
            logger.makeRecord(
                logger.name,
                logging_level,
                file.decode("utf-8", "replace"),
                line,
                "%s",
                (text.decode("utf-8", "replace"),),
                None,
                func=function.decode("utf-8", "replace"),
            )
        )


_on_log: Final = _raw.swiftmmkv_log_callback(_log)


def _no_release() -> object:
    """A release function that is NULL: the handler's context is nothing to release."""
    return _raw.swiftmmkv_context_release()


def install() -> None:
    """Sends MMKV's messages to this module, in place of standard error."""
    _raw.swiftmmkv_log_set_handler(None, _on_log, _no_release())
    atexit.register(_uninstall)


def _uninstall() -> None:
    # A message that is logged while the interpreter shuts down must not call into it.
    _raw.swiftmmkv_log_set_handler(None, _raw.swiftmmkv_log_callback(), _no_release())


def log_level() -> LogLevel:
    """The least severe level that MMKV logs, which starts as `LogLevel.WARNING`."""
    return LogLevel(_raw.swiftmmkv_log_minimum_level())


def set_log_level(level: LogLevel, /) -> None:
    """Sets the least severe level that MMKV logs, for every store in the process.
    `LogLevel.NONE` logs nothing.

    This decides which messages MMKV makes at all. The `swiftmmkv` logger then filters
    them by its own level as it does any record, so to see MMKV's info messages set both::

        swiftmmkv.set_log_level(LogLevel.INFO)
        swiftmmkv.logger.setLevel(logging.INFO)
    """
    _raw.swiftmmkv_log_set_minimum_level(int(LogLevel(level)))


def set_log_handler(handler: Callable[[LogMessage], object] | None, /) -> None:
    """Sends every message MMKV logs to `handler`, in place of the `swiftmmkv` logger, or
    with `None` sends them to the logger again.

    The handler runs on the thread that logged the message, usually while MMKV holds the
    lock of the store the message is about. It must not read or write a store. The same
    holds for the handlers of the `swiftmmkv` logger.
    """
    global _handler
    if handler is not None and not callable(handler):
        raise TypeError("A log handler must be callable.")
    _handler = handler


class IntegrityFailureKind(enum.IntEnum):
    """The check a store's file failed as it was loaded."""

    #: The file's contents do not match their checksum.
    CHECKSUM = _raw.SWIFTMMKV_INTEGRITY_FAILURE_CHECKSUM
    #: The file is not as long as it records itself to be.
    FILE_LENGTH = _raw.SWIFTMMKV_INTEGRITY_FAILURE_FILE_LENGTH


@dataclass(frozen=True, slots=True)
class IntegrityFailure:
    """A store's file failed its integrity check as it was loaded.

    MMKV reports the store's identifier alone, so stores with the same identifier in
    different directories cannot be told apart.
    """

    id: StoreID
    kind: IntegrityFailureKind


def on_integrity_failure(callback: Callable[[IntegrityFailure], object], /) -> Subscription:
    """Calls `callback` whenever the file of any store in this process fails its integrity
    check, until the subscription is cancelled. Subscribe before opening the stores to be
    told about.

    A file can fail its check after the process is killed in the middle of a write. The
    store's `recovery` setting decides what becomes of its contents.

    The callback runs on the thread that was loading the file, while MMKV holds the store's
    lock. It must not read or write a store.
    """
    if not callable(callback):
        raise TypeError("A callback must be callable.")

    def deliver(id: str, kind: int) -> None:
        callback(IntegrityFailure(StoreID(id), IntegrityFailureKind(kind)))

    return _changes.subscribe_to_integrity_failures(deliver)
