"""`MMKVError` and `Status`, and each status the package can cause, caused for real."""

from __future__ import annotations

import os
import pickle
import re
from collections.abc import Iterator
from datetime import timedelta
from pathlib import Path

import pytest

import swiftmmkv
from swiftmmkv import Configuration, Directory, Encryption, MMKVError, Mode, Status, Store, _raw

HEADER = Path(
    os.environ.get("SWIFTMMKV_HEADER")
    or Path(__file__).resolve().parents[2] / "Sources" / "CSwiftMMKV" / "include" / "swiftmmkv.h"
)


def header_statuses() -> dict[str, int]:
    """Each `SWIFTMMKV_` status of the header, without its prefix, and its value."""
    source = HEADER.read_text()
    section = source[source.index("// MARK: - Status") : source.index("swiftmmkv_status_message")]
    return {
        name: int(value)
        for name, value in re.findall(r"^#define SWIFTMMKV_([A-Z_]+) (\d+)$", section, re.MULTILINE)
    }


def corrupt(path: Path) -> None:
    """Damages a store's file the way the Swift backup tests do."""
    with path.open("r+b") as file:
        file.seek(4)
        file.write(b"\xff" * 8)


@pytest.fixture
def opened() -> Iterator[list[Store]]:
    """The stores a test opens, which are closed after it."""
    stores: list[Store] = []
    yield stores
    for store in stores:
        store.close()


def open_in(opened: list[Store], directory: os.PathLike[str] | str, **options: object) -> Store:
    options.setdefault("mode", Mode.SINGLE_PROCESS)
    store = swiftmmkv.open(directory, **options)  # type: ignore[call-overload]
    opened.append(store)
    return store


# MARK: - The error


def test_an_error_has_its_status_code_and_message() -> None:
    error = MMKVError(_raw.SWIFTMMKV_STORE_IS_OPEN)

    assert error.status is Status.STORE_IS_OPEN
    assert error.code == _raw.SWIFTMMKV_STORE_IS_OPEN
    assert error.message == _raw.swiftmmkv_status_message(error.code).decode("utf-8")
    assert error.message


def test_an_error_reads_as_its_message() -> None:
    error = MMKVError(Status.BACKUP_INVALID)

    assert str(error) == error.message


def test_an_error_is_an_exception() -> None:
    assert issubclass(MMKVError, Exception)
    assert isinstance(MMKVError(Status.OPEN_FAILED), Exception)


def test_an_error_pickles() -> None:
    error = MMKVError(Status.REKEY_FAILED)

    copy = pickle.loads(pickle.dumps(error))

    assert type(copy) is MMKVError
    assert (copy.status, copy.code, copy.message) == (error.status, error.code, error.message)


def test_an_unknown_code_is_an_unknown_error_that_keeps_its_code() -> None:
    error = MMKVError(999)

    assert error.status is Status.UNKNOWN_ERROR
    assert error.code == 999
    assert pickle.loads(pickle.dumps(error)).code == 999


def test_status_has_every_status_of_the_header_with_its_value() -> None:
    statuses = header_statuses()

    assert "OK" in statuses and "STORE_IS_CLOSED" in statuses
    assert {status.name: status.value for status in Status} == statuses


def test_every_status_has_a_message_of_its_own() -> None:
    messages = {MMKVError(status).message for status in Status if status is not Status.OK}

    assert len(messages) == len(Status) - 1


# MARK: - Opening


def test_an_empty_identifier_does_not_open(tmp_path: Path) -> None:
    with pytest.raises(MMKVError) as caught:
        swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, id="")

    assert caught.value.status is Status.OPEN_FAILED


def test_an_empty_directory_does_not_open() -> None:
    with pytest.raises(MMKVError) as caught:
        swiftmmkv.open("", mode=Mode.SINGLE_PROCESS)

    assert caught.value.status is Status.OPEN_FAILED


@pytest.mark.parametrize("key", [b"", b"k" * 17], ids=["empty", "longer than the cipher allows"])
def test_a_key_of_the_wrong_length_does_not_open(tmp_path: Path, key: bytes) -> None:
    with pytest.raises(MMKVError) as caught:
        swiftmmkv.open(tmp_path, mode=Mode.SINGLE_PROCESS, encryption=Encryption.aes128(key))

    assert caught.value.status is Status.INVALID_ENCRYPTION_KEY


def test_a_key_of_the_wrong_length_is_not_rekeyed_to(store: Store) -> None:
    store.set("key", "value")

    with pytest.raises(MMKVError) as caught:
        store.rekey(Encryption.aes256(b"k" * 33))

    assert caught.value.status is Status.INVALID_ENCRYPTION_KEY
    assert store.get("key", str) == "value"


@pytest.mark.parametrize(
    "option",
    [
        {"mode": 7},
        {"mode": Mode.SINGLE_PROCESS, "recovery": 7},
        {"mode": Mode.SINGLE_PROCESS, "file_protection": 7},
        {"mode": Mode.SINGLE_PROCESS, "encryption": Encryption(7, b"key")},  # type: ignore[arg-type]
    ],
    ids=["mode", "recovery", "file protection", "cipher"],
)
def test_an_option_that_is_not_one_of_its_values_does_not_open(
    tmp_path: Path, option: dict[str, object]
) -> None:
    with pytest.raises(MMKVError) as caught:
        swiftmmkv.open(Configuration(directory=tmp_path, **option))  # type: ignore[arg-type]

    assert caught.value.status is Status.INVALID_ARGUMENT


def test_a_cipher_that_is_not_one_of_its_values_is_not_rekeyed_to(store: Store) -> None:
    with pytest.raises(MMKVError) as caught:
        store.rekey(Encryption(7, b"key"))  # type: ignore[arg-type]

    assert caught.value.status is Status.INVALID_ARGUMENT


# MARK: - Maintenance


def test_a_read_only_store_is_not_rekeyed(tmp_path: Path, opened: list[Store]) -> None:
    open_in(opened, tmp_path, id="settings").set("key", "value")
    opened.pop().close()
    store = open_in(opened, tmp_path, id="settings", read_only=True)

    with pytest.raises(MMKVError) as caught:
        store.rekey(Encryption.aes128("secret"))

    assert caught.value.status is Status.REKEY_FAILED
    assert store.get("key", str) == "value"


def test_a_read_only_store_does_not_disable_expiry(tmp_path: Path, opened: list[Store]) -> None:
    open_in(opened, tmp_path, id="settings").set("otp", "1", expiry=timedelta(hours=1))
    opened.pop().close()
    store = open_in(opened, tmp_path, id="settings", read_only=True)
    assert store.expiry_enabled

    with pytest.raises(MMKVError) as caught:
        store.disable_expiry()

    assert caught.value.status is Status.DISABLE_EXPIRY_FAILED
    assert store.expiry_enabled


# MARK: - Open stores


def test_an_open_store_is_not_removed(tmp_path: Path, opened: list[Store]) -> None:
    store = open_in(opened, tmp_path, id="settings")
    store.set("key", "value")

    with pytest.raises(MMKVError) as caught:
        Directory(tmp_path).remove_store("settings")

    assert caught.value.status is Status.STORE_IS_OPEN
    assert store.get("key", str) == "value"


def test_a_backup_that_is_open_is_not_replaced(tmp_path: Path, opened: list[Store]) -> None:
    store = open_in(opened, tmp_path / "stores", id="settings")
    store.set("key", "value")
    store.back_up(tmp_path / "backup")
    len(open_in(opened, tmp_path / "backup", id="settings"))

    with pytest.raises(MMKVError) as caught:
        store.back_up(tmp_path / "backup")

    assert caught.value.status is Status.STORE_IS_OPEN


def test_removing_every_store_leaves_the_open_ones_and_says_so(
    tmp_path: Path, opened: list[Store]
) -> None:
    directory = Directory(tmp_path)
    open_in(opened, tmp_path, id="closed").set("key", "value")
    opened.pop().close()
    open_in(opened, tmp_path, id="open").set("key", "value")

    with pytest.raises(MMKVError) as caught:
        directory.remove_all_stores()

    assert caught.value.status is Status.STORES_ARE_OPEN
    assert not directory.contains_store("closed")
    assert directory.contains_store("open")


def test_backing_up_every_store_onto_open_copies_is_refused(
    tmp_path: Path, opened: list[Store]
) -> None:
    store = open_in(opened, tmp_path / "stores", id="settings")
    store.set("key", "value")
    store.back_up(tmp_path / "backup")
    len(open_in(opened, tmp_path / "backup", id="settings"))

    with pytest.raises(MMKVError) as caught:
        Directory(tmp_path / "stores").back_up_all_stores(tmp_path / "backup")

    assert caught.value.status is Status.STORES_ARE_OPEN


# MARK: - Directories


def test_a_directory_that_is_a_file_cannot_be_listed(tmp_path: Path) -> None:
    file = tmp_path / "file"
    file.write_bytes(b"")

    with pytest.raises(MMKVError) as caught:
        Directory(file).remove_all_stores()

    assert caught.value.status is Status.DIRECTORY_UNREADABLE


def test_a_backup_that_is_a_file_cannot_be_listed(tmp_path: Path) -> None:
    file = tmp_path / "file"
    file.write_bytes(b"")

    with pytest.raises(MMKVError) as caught:
        Directory(tmp_path / "stores").restore_all_stores(file)

    assert caught.value.status is Status.DIRECTORY_UNREADABLE


# MARK: - Backups


def test_a_store_is_not_backed_up_onto_its_own_directory(store: Store) -> None:
    with pytest.raises(MMKVError) as caught:
        store.back_up(os.path.join(store.directory, "."))

    assert caught.value.status is Status.BACKUP_IS_STORE_DIRECTORY


def test_a_store_is_not_restored_from_its_own_directory(store: Store) -> None:
    with pytest.raises(MMKVError) as caught:
        store.restore(store.directory)

    assert caught.value.status is Status.BACKUP_IS_STORE_DIRECTORY


def test_a_backup_into_a_file_fails(tmp_path: Path, opened: list[Store]) -> None:
    open_in(opened, tmp_path / "stores", id="settings").set("key", "value")
    file = tmp_path / "file"
    file.write_bytes(b"")

    with pytest.raises(MMKVError) as caught:
        Directory(tmp_path / "stores").back_up_store("settings", file)

    assert caught.value.status is Status.BACKUP_FAILED


def test_a_store_backed_up_into_a_file_fails(tmp_path: Path, opened: list[Store]) -> None:
    store = open_in(opened, tmp_path / "stores", id="settings")
    store.set("key", "value")
    file = tmp_path / "file"
    file.write_bytes(b"")

    with pytest.raises(MMKVError) as caught:
        store.back_up(file)

    assert caught.value.status is Status.BACKUP_FAILED


def test_every_store_backed_up_into_a_file_fails(tmp_path: Path, opened: list[Store]) -> None:
    open_in(opened, tmp_path / "stores", id="settings").set("key", "value")
    file = tmp_path / "file"
    file.write_bytes(b"")

    with pytest.raises(MMKVError) as caught:
        Directory(tmp_path / "stores").back_up_all_stores(file)

    assert caught.value.status is Status.STORES_NOT_BACKED_UP


def test_a_damaged_backup_is_not_restored(tmp_path: Path, opened: list[Store]) -> None:
    store = open_in(opened, tmp_path / "stores", id="settings")
    store.set("theme", "dark")
    store.back_up(tmp_path / "backup")
    corrupt(tmp_path / "backup" / "settings")
    store.set("theme", "light")

    with pytest.raises(MMKVError) as caught:
        store.restore(tmp_path / "backup")

    assert caught.value.status is Status.BACKUP_INVALID
    assert store.get("theme", str) == "light"


def test_a_damaged_backup_is_not_restored_by_the_directory(
    tmp_path: Path, opened: list[Store]
) -> None:
    store = open_in(opened, tmp_path / "stores", id="settings")
    store.set("theme", "dark")
    store.back_up(tmp_path / "backup")
    corrupt(tmp_path / "backup" / "settings")

    with pytest.raises(MMKVError) as caught:
        Directory(tmp_path / "stores").restore_all_stores(tmp_path / "backup")

    assert caught.value.status is Status.BACKUP_INVALID


def test_a_read_only_store_is_not_restored(tmp_path: Path, opened: list[Store]) -> None:
    writable = open_in(opened, tmp_path / "stores", id="settings")
    writable.set("theme", "dark")
    writable.back_up(tmp_path / "backup")
    writable.set("theme", "light")
    writable.close()
    store = open_in(opened, tmp_path / "stores", id="settings", read_only=True)

    with pytest.raises(MMKVError) as caught:
        store.restore(tmp_path / "backup")

    assert caught.value.status is Status.RESTORE_FAILED
    assert store.get("theme", str) == "light"


def test_a_store_is_not_restored_where_no_directory_can_be(
    tmp_path: Path, opened: list[Store]
) -> None:
    store = open_in(opened, tmp_path / "stores", id="settings")
    store.set("key", "value")
    store.back_up(tmp_path / "backup")
    file = tmp_path / "file"
    file.write_bytes(b"")

    with pytest.raises(MMKVError) as caught:
        Directory(file / "stores").restore_store("settings", tmp_path / "backup")

    assert caught.value.status is Status.RESTORE_FAILED


def test_stores_are_not_restored_where_no_directory_can_be(
    tmp_path: Path, opened: list[Store]
) -> None:
    store = open_in(opened, tmp_path / "stores", id="settings")
    store.set("key", "value")
    store.back_up(tmp_path / "backup")
    file = tmp_path / "file"
    file.write_bytes(b"")

    with pytest.raises(MMKVError) as caught:
        Directory(file / "stores").restore_all_stores(tmp_path / "backup")

    assert caught.value.status is Status.STORES_NOT_RESTORED


# MARK: - Suspended and closed stores


@pytest.fixture
def suspended(tmp_path: Path) -> Iterator[Store]:
    store = swiftmmkv.open(tmp_path / "stores", mode=Mode.MULTI_PROCESS, id="settings")
    store.set("otp", "1", expiry=timedelta(hours=1))
    store.back_up(tmp_path / "backup")
    store.suspend()
    yield store
    store.resume()
    store.close()


@pytest.mark.parametrize(
    "operation",
    ["rekey", "disable_expiry", "back_up", "restore", "back_up_all", "restore_all"],
)
def test_a_suspended_store_turns_away_what_reports_a_status(
    suspended: Store, tmp_path: Path, operation: str
) -> None:
    directory = Directory(tmp_path / "stores")
    operations = {
        "rekey": lambda: suspended.rekey(Encryption.aes128("secret")),
        "disable_expiry": suspended.disable_expiry,
        "back_up": lambda: suspended.back_up(tmp_path / "backup"),
        "restore": lambda: suspended.restore(tmp_path / "backup"),
        "back_up_all": lambda: directory.back_up_all_stores(tmp_path / "backup"),
        "restore_all": lambda: directory.restore_all_stores(tmp_path / "backup"),
    }

    with pytest.raises(MMKVError) as caught:
        operations[operation]()

    assert caught.value.status is Status.STORE_IS_SUSPENDED


@pytest.mark.parametrize("operation", ["rekey", "disable_expiry", "back_up", "restore"])
def test_a_closed_store_turns_away_what_reports_a_status(tmp_path: Path, operation: str) -> None:
    store = swiftmmkv.open(tmp_path / "stores", mode=Mode.SINGLE_PROCESS, id="settings")
    store.set("key", "value")
    store.back_up(tmp_path / "backup")
    store.close()
    operations = {
        "rekey": lambda: store.rekey(None),
        "disable_expiry": store.disable_expiry,
        "back_up": lambda: store.back_up(tmp_path / "backup"),
        "restore": lambda: store.restore(tmp_path / "backup"),
    }

    with pytest.raises(MMKVError) as caught:
        operations[operation]()

    assert caught.value.status is Status.STORE_IS_CLOSED
