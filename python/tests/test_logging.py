"""MMKV's messages reach `logging` and a handler the user sets, and integrity failures reach a
callback.

Logging is shared by the whole process, so every test that changes the level or the handler
puts it back afterwards."""

from __future__ import annotations

import logging
import os
import subprocess
import sys
import uuid
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest

import swiftmmkv
from swiftmmkv import (
    Directory,
    IntegrityFailure,
    IntegrityFailureKind,
    LogLevel,
    LogMessage,
    Mode,
    Store,
    StoreID,
)


class Recorder(logging.Handler):
    """Keeps the records it is given."""

    def __init__(self) -> None:
        super().__init__(logging.DEBUG)
        self.records: list[logging.LogRecord] = []

    def emit(self, record: logging.LogRecord) -> None:
        self.records.append(record)


@pytest.fixture(autouse=True)
def restore_logging() -> Iterator[None]:
    """Puts back MMKV's level, the log handler, and the logger's level."""
    level = swiftmmkv.log_level()
    logger_level = swiftmmkv.logger.level
    yield
    swiftmmkv.set_log_handler(None)
    swiftmmkv.set_log_level(level)
    swiftmmkv.logger.setLevel(logger_level)


@pytest.fixture
def records() -> Iterator[list[logging.LogRecord]]:
    """The records the `swiftmmkv` logger handles during the test, at any level."""
    recorder = Recorder()
    swiftmmkv.logger.addHandler(recorder)
    swiftmmkv.logger.setLevel(logging.DEBUG)
    yield recorder.records
    swiftmmkv.logger.removeHandler(recorder)


@pytest.fixture
def messages() -> list[LogMessage]:
    """The messages a log handler is given during the test."""
    messages: list[LogMessage] = []
    swiftmmkv.set_log_handler(messages.append)
    return messages


def log_an_error(store: Store) -> None:
    """Makes MMKV log an error: a one-character string read as a double runs out of bytes."""
    store.set("text", "1")
    assert store.get("text", float) is None


def corrupt_checksum(directory: Directory, id: str) -> None:
    """Overwrites the checksums of a closed store's `.crc` file, as the Swift tests do."""
    path = Path(directory, id + ".crc")
    data = bytearray(path.read_bytes())
    data[0:4] = b"\xff" * 4
    data[32:40] = b"\xff" * 8
    path.write_bytes(bytes(data))


def corrupt_recorded_size(directory: Directory, id: str) -> None:
    """Overwrites the size a closed store's `.crc` file records, as the Swift tests do."""
    path = Path(directory, id + ".crc")
    data = bytearray(path.read_bytes())
    data[28:36] = b"\xff" * 8
    path.write_bytes(bytes(data))


def closed_store(directory: Directory) -> str:
    """The identifier of a store that holds a value and is closed."""
    id = f"integrity-{uuid.uuid4()}"
    with directory.open(mode=Mode.SINGLE_PROCESS, id=id) as store:
        store.set("key", "value")
    return id


# MARK: - Levels


def test_the_level_starts_as_warning() -> None:
    code = "import swiftmmkv; print(swiftmmkv.log_level().name)"
    result = subprocess.run(
        [sys.executable, "-c", code],
        capture_output=True,
        text=True,
        timeout=60,
        env={**os.environ, "PYTHONPATH": os.pathsep.join(sys.path)},
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "WARNING"


@pytest.mark.parametrize("level", list(LogLevel))
def test_the_level_that_is_set_is_the_level(level: LogLevel) -> None:
    swiftmmkv.set_log_level(level)

    assert swiftmmkv.log_level() is level


def test_a_level_that_is_not_one_is_refused() -> None:
    with pytest.raises(ValueError):
        swiftmmkv.set_log_level(99)  # type: ignore[arg-type]


def test_log_levels_have_the_values_of_the_header() -> None:
    assert [(level.name, int(level)) for level in LogLevel] == [
        ("INFO", 1),
        ("WARNING", 2),
        ("ERROR", 3),
        ("NONE", 4),
    ]


# MARK: - The logger


def test_an_error_reaches_the_logger_as_an_error(
    store: Store, records: list[logging.LogRecord]
) -> None:
    log_an_error(store)

    errors = [record for record in records if record.levelno == logging.ERROR]
    assert errors
    assert all(record.name == "swiftmmkv" for record in errors)


def test_a_record_has_the_mmkv_source_file_function_and_line(
    store: Store, records: list[logging.LogRecord]
) -> None:
    log_an_error(store)

    record = next(record for record in records if record.levelno == logging.ERROR)
    assert record.pathname.endswith(".cpp")
    assert record.filename == os.path.basename(record.pathname)
    assert record.funcName == "getDouble"
    assert record.lineno > 0
    assert record.getMessage()


def test_info_messages_reach_the_logger_once_the_level_is_info(
    records: list[logging.LogRecord],
) -> None:
    swiftmmkv.set_log_level(LogLevel.INFO)

    with swiftmmkv.open_temporary() as store:
        store.set("key", "value")

    infos = [record for record in records if record.levelno == logging.INFO]
    assert infos
    assert any("mmkv.default" in record.getMessage() for record in infos)
    assert all(record.pathname and record.funcName and record.lineno > 0 for record in infos)


def test_info_messages_are_not_made_at_the_warning_level(
    records: list[logging.LogRecord],
) -> None:
    swiftmmkv.set_log_level(LogLevel.WARNING)

    with swiftmmkv.open_temporary() as store:
        store.set("key", "value")

    assert not [record for record in records if record.levelno < logging.WARNING]


def test_the_error_level_leaves_out_warnings(
    store: Store, records: list[logging.LogRecord]
) -> None:
    swiftmmkv.set_log_level(LogLevel.ERROR)

    log_an_error(store)
    with swiftmmkv.open_temporary() as other:
        other.set("key", "value")

    assert records
    assert all(record.levelno == logging.ERROR for record in records)


def test_the_none_level_silences_every_message(
    store: Store, records: list[logging.LogRecord]
) -> None:
    swiftmmkv.set_log_level(LogLevel.NONE)

    log_an_error(store)

    assert records == []


def test_the_logger_level_filters_messages_too(store: Store) -> None:
    recorder = Recorder()
    swiftmmkv.logger.addHandler(recorder)
    swiftmmkv.logger.setLevel(logging.CRITICAL)
    try:
        log_an_error(store)
    finally:
        swiftmmkv.logger.removeHandler(recorder)

    assert recorder.records == []


# MARK: - A log handler


def test_a_log_handler_receives_messages(store: Store, messages: list[LogMessage]) -> None:
    log_an_error(store)

    message = next(message for message in messages if message.level is LogLevel.ERROR)
    assert isinstance(message, LogMessage)
    assert message.text
    assert message.file.endswith(".cpp")
    assert message.function == "getDouble"
    assert message.line > 0


def test_a_log_handler_takes_the_place_of_the_logger(
    store: Store, records: list[logging.LogRecord], messages: list[LogMessage]
) -> None:
    log_an_error(store)

    assert messages
    assert records == []


def test_a_log_handler_receives_info_messages_once_the_level_is_info(
    messages: list[LogMessage],
) -> None:
    swiftmmkv.set_log_level(LogLevel.INFO)

    with swiftmmkv.open_temporary() as store:
        store.set("key", "value")

    assert any(message.level is LogLevel.INFO for message in messages)


def test_no_log_handler_gives_messages_back_to_the_logger(
    store: Store, records: list[logging.LogRecord], messages: list[LogMessage]
) -> None:
    swiftmmkv.set_log_handler(None)

    log_an_error(store)

    assert messages == []
    assert records


def test_a_log_handler_must_be_callable() -> None:
    with pytest.raises(TypeError):
        swiftmmkv.set_log_handler("print")  # type: ignore[arg-type]


def test_a_log_message_is_immutable() -> None:
    message = LogMessage(LogLevel.ERROR, "text", "MMKV.cpp", "load", 12)

    with pytest.raises(AttributeError):
        message.text = "other"  # type: ignore[misc]
    assert message == LogMessage(LogLevel.ERROR, "text", "MMKV.cpp", "load", 12)


def test_an_error_a_log_handler_raises_does_not_break_the_operation(
    store: Store, unraisable: list[Any]
) -> None:
    def handler(message: LogMessage) -> None:
        raise RuntimeError("from the handler")

    swiftmmkv.set_log_handler(handler)
    store.set("text", "1")

    assert store.get("text", float) is None
    assert store.get("text", str) == "1"
    assert store.set("other", "value")
    errors = [caught.exc_value for caught in unraisable]
    assert errors
    assert all(isinstance(error, RuntimeError) for error in errors)
    assert str(errors[0]) == "from the handler"


# MARK: - Integrity failures


def test_a_file_that_fails_its_checksum_is_reported(directory: Directory) -> None:
    id = closed_store(directory)
    corrupt_checksum(directory, id)
    failures: list[IntegrityFailure] = []

    with swiftmmkv.on_integrity_failure(failures.append):
        with directory.open(mode=Mode.SINGLE_PROCESS, id=id) as store:
            len(store)

    assert [failure for failure in failures if failure.id == id] == [
        IntegrityFailure(StoreID(id), IntegrityFailureKind.CHECKSUM)
    ]


def test_a_file_shorter_than_it_records_is_reported(directory: Directory) -> None:
    id = closed_store(directory)
    corrupt_recorded_size(directory, id)
    failures: list[IntegrityFailure] = []

    with swiftmmkv.on_integrity_failure(failures.append):
        with directory.open(mode=Mode.SINGLE_PROCESS, id=id) as store:
            len(store)

    assert [failure for failure in failures if failure.id == id] == [
        IntegrityFailure(StoreID(id), IntegrityFailureKind.FILE_LENGTH)
    ]


def test_an_integrity_failure_names_the_store(directory: Directory) -> None:
    id = closed_store(directory)
    corrupt_checksum(directory, id)
    failures: list[IntegrityFailure] = []

    with swiftmmkv.on_integrity_failure(failures.append):
        with directory.open(mode=Mode.SINGLE_PROCESS, id=id) as store:
            len(store)

    failure = next(failure for failure in failures if failure.id == id)
    assert isinstance(failure.id, StoreID)
    assert isinstance(failure.kind, IntegrityFailureKind)


def test_an_intact_file_is_not_reported(directory: Directory) -> None:
    id = closed_store(directory)
    failures: list[IntegrityFailure] = []

    with swiftmmkv.on_integrity_failure(failures.append):
        with directory.open(mode=Mode.SINGLE_PROCESS, id=id) as store:
            assert store.get("key", str) == "value"

    assert not [failure for failure in failures if failure.id == id]


def test_an_integrity_failure_is_logged_as_an_error(
    directory: Directory, records: list[logging.LogRecord]
) -> None:
    id = closed_store(directory)
    corrupt_checksum(directory, id)

    with directory.open(mode=Mode.SINGLE_PROCESS, id=id) as store:
        len(store)

    assert any(record.levelno == logging.ERROR and id in record.getMessage() for record in records)


def test_a_cancelled_integrity_subscription_is_not_called(directory: Directory) -> None:
    id = closed_store(directory)
    corrupt_checksum(directory, id)
    failures: list[IntegrityFailure] = []
    subscription = swiftmmkv.on_integrity_failure(failures.append)

    subscription.cancel()
    with directory.open(mode=Mode.SINGLE_PROCESS, id=id) as store:
        len(store)

    assert subscription.cancelled
    assert failures == []


def test_cancelling_an_integrity_subscription_twice_is_harmless() -> None:
    subscription = swiftmmkv.on_integrity_failure(lambda failure: None)

    subscription.cancel()
    subscription.cancel()

    assert subscription.cancelled


def test_an_integrity_callback_must_be_callable() -> None:
    with pytest.raises(TypeError):
        swiftmmkv.on_integrity_failure(None)  # type: ignore[arg-type]


def test_an_error_an_integrity_callback_raises_does_not_break_the_store(
    directory: Directory, unraisable: list[Any]
) -> None:
    id = closed_store(directory)
    corrupt_checksum(directory, id)

    def callback(failure: IntegrityFailure) -> None:
        if failure.id == id:
            raise RuntimeError("from the callback")

    with swiftmmkv.on_integrity_failure(callback):
        with directory.open(mode=Mode.SINGLE_PROCESS, id=id) as store:
            assert len(store) == 0
            assert store.set("key", "other")

    assert any(isinstance(caught.exc_value, RuntimeError) for caught in unraisable)
