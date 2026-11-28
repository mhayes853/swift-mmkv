"""Sizes, trimming, syncing, releasing memory, re-encrypting, suspension, and checking for
external changes."""

from __future__ import annotations

from collections.abc import Iterator

import pytest

import swiftmmkv
from swiftmmkv import ChangeBatch, Directory, Encryption, Key, MMKVError, Mode, Status, Store

NAME = Key("name", str)


@pytest.fixture
def shared(directory: Directory) -> Iterator[Store]:
    """A multi-process store with a value, which is resumed and closed after the test."""
    store = directory.open(mode=Mode.MULTI_PROCESS, id="settings")
    store.set("theme", "dark")
    yield store
    store.resume()
    store.close()


# MARK: - Sizes


def test_a_new_store_takes_a_page_and_holds_no_data(store: Store) -> None:
    assert store.byte_size > 0
    assert store.used_byte_size == 0


def test_writes_use_the_file_and_grow_it(store: Store) -> None:
    initial = store.byte_size

    for index in range(100):
        store.set(f"key.{index}", bytes(1000))

    assert store.used_byte_size >= 100_000
    assert store.byte_size >= store.used_byte_size
    assert store.byte_size > initial


def test_removing_values_does_not_shrink_the_file(store: Store) -> None:
    for index in range(100):
        store.set(f"key.{index}", bytes(1000))
    size = store.byte_size

    for index in range(99):
        store.remove(f"key.{index}")

    assert store.byte_size == size


def test_trimming_drops_the_space_removed_values_left(store: Store) -> None:
    for index in range(100):
        store.set(f"key.{index}", bytes(1000))
    for index in range(99):
        store.remove(f"key.{index}")
    size, used = store.byte_size, store.used_byte_size

    store.trim()

    assert store.byte_size < size
    assert store.used_byte_size < used
    assert store.keys() == {"key.99"}
    assert store.get("key.99", bytes) == bytes(1000)


def test_clearing_without_keeping_capacity_shrinks_the_file(store: Store) -> None:
    initial = store.byte_size
    for index in range(100):
        store.set(f"key.{index}", bytes(1000))

    store.clear()

    assert store.byte_size == initial
    assert len(store) == 0


def test_clearing_keeping_capacity_keeps_the_file_size(store: Store) -> None:
    for index in range(100):
        store.set(f"key.{index}", bytes(1000))
    size = store.byte_size

    store.clear(keep_capacity=True)

    assert store.byte_size == size
    assert len(store) == 0


# MARK: - Syncing and memory


def test_syncing_keeps_every_value(store: Store) -> None:
    store.set("theme", "dark")

    store.sync()

    assert store.get("theme", str) == "dark"


def test_synced_values_are_in_the_files(directory: Directory) -> None:
    store = directory.open(mode=Mode.SINGLE_PROCESS, id="settings")
    store.set("theme", "dark")
    store.sync()
    store.close()

    assert directory.is_store_valid("settings")
    with directory.open(mode=Mode.SINGLE_PROCESS, id="settings") as reopened:
        assert reopened.get("theme", str) == "dark"


def test_values_are_read_after_memory_is_released(store: Store) -> None:
    store.set("theme", "dark")
    store.set("count", 3)
    store.set(NAME, "blob")

    store.release_memory()

    assert store.get("theme", str) == "dark"
    assert store.get("count", int) == 3
    assert store[NAME] == "blob"
    assert store.keys() == {"theme", "count", "name"}


def test_writes_work_after_memory_is_released(store: Store) -> None:
    store.release_memory()

    assert store.set("theme", "dark")
    assert store.get("theme", str) == "dark"


def test_releasing_memory_tells_listeners_nothing(store: Store) -> None:
    store.set("theme", "dark")
    batches: list[ChangeBatch] = []
    store.subscribe(batches.append)

    store.release_memory()
    store.get("theme", str)

    assert batches == []


# MARK: - Re-encrypting


def reopened(directory: Directory, encryption: Encryption | None) -> dict[str, str | None]:
    """The values of a store, read by opening it again with `encryption`."""
    with directory.open(mode=Mode.SINGLE_PROCESS, id="settings", encryption=encryption) as store:
        return {"theme": store.get("theme", str), "token": store.get("token", str)}


def test_a_plain_store_is_encrypted(directory: Directory) -> None:
    store = directory.open(mode=Mode.SINGLE_PROCESS, id="settings")
    store.set("theme", "dark")
    store.set("token", "abc")

    store.rekey(Encryption.aes128("secret"))

    assert store.get("theme", str) == "dark"
    store.close()
    assert reopened(directory, Encryption.aes128("secret")) == {"theme": "dark", "token": "abc"}


def test_an_encrypted_store_is_encrypted_with_another_cipher_and_key(
    directory: Directory,
) -> None:
    store = directory.open(
        mode=Mode.SINGLE_PROCESS, id="settings", encryption=Encryption.aes128("first")
    )
    store.set("theme", "dark")
    store.set("token", "abc")

    store.rekey(Encryption.aes256(b"second key that is 32 bytes long"))

    assert store.get("token", str) == "abc"
    store.close()
    assert reopened(directory, Encryption.aes256(b"second key that is 32 bytes long")) == {
        "theme": "dark",
        "token": "abc",
    }


def test_an_encrypted_store_is_decrypted(directory: Directory) -> None:
    store = directory.open(
        mode=Mode.SINGLE_PROCESS, id="settings", encryption=Encryption.aes256("secret")
    )
    store.set("theme", "dark")
    store.set("token", "abc")

    store.rekey(None)

    assert store.get("theme", str) == "dark"
    store.close()
    assert reopened(directory, None) == {"theme": "dark", "token": "abc"}


def test_an_encrypted_store_does_not_read_without_its_key(directory: Directory) -> None:
    store = directory.open(mode=Mode.SINGLE_PROCESS, id="settings")
    store.set("theme", "dark")
    store.set("token", "abc")
    store.rekey(Encryption.aes128("secret"))
    store.close()

    assert reopened(directory, None) == {"theme": None, "token": None}


def test_a_rekeyed_store_takes_writes(store: Store) -> None:
    store.rekey(Encryption.aes128("secret"))

    assert store.set("theme", "dark")
    assert store.get("theme", str) == "dark"


# MARK: - Suspension


def test_a_multi_process_store_is_suspended_until_it_is_resumed(shared: Store) -> None:
    assert not shared.suspended

    shared.suspend()
    assert shared.suspended

    shared.resume()
    assert not shared.suspended


def test_a_suspended_store_reads_nothing(shared: Store) -> None:
    shared.set(NAME, "blob")

    shared.suspend()

    assert shared.get("theme", str) is None
    assert shared.get(NAME) is None
    assert "theme" not in shared
    assert len(shared) == 0
    assert shared.keys() == frozenset()
    assert shared.value_size("theme") is None


def test_a_suspended_store_writes_nothing_and_says_so(shared: Store) -> None:
    shared.suspend()

    assert shared.set("theme", "light") is False
    assert shared.set_many({"a": 1}) is False
    assert shared.remove("theme") is False
    shared.clear()

    shared.resume()
    assert shared.keys() == {"theme"}
    assert shared.get("theme", str) == "dark"


def test_a_resumed_store_reads_its_values_again(shared: Store) -> None:
    shared.suspend()

    shared.resume()

    assert shared.get("theme", str) == "dark"
    assert shared.set("theme", "light")
    assert shared.get("theme", str) == "light"


def test_resuming_tells_listeners_of_an_external_change(shared: Store) -> None:
    batches: list[ChangeBatch] = []
    shared.subscribe(batches.append)
    shared.suspend()

    shared.resume()

    assert [(batch.keys, batch.is_external) for batch in batches] == [((), True)]


def test_a_suspended_store_turns_away_what_reports_a_status(shared: Store) -> None:
    shared.suspend()

    with pytest.raises(MMKVError) as caught:
        shared.rekey(Encryption.aes128("secret"))

    assert caught.value.status is Status.STORE_IS_SUSPENDED


def test_suspending_a_single_process_store_does_nothing(store: Store) -> None:
    store.set("theme", "dark")

    store.suspend()

    assert not store.suspended
    assert store.get("theme", str) == "dark"
    assert store.set("theme", "light")
    store.resume()


def test_suspending_a_store_suspends_every_store_over_its_files(
    shared: Store, directory: Directory
) -> None:
    other = directory.open(mode=Mode.MULTI_PROCESS, id="settings")

    shared.suspend()

    assert other.suspended
    assert other.get("theme", str) is None
    shared.resume()
    other.close()


def test_a_closed_store_is_not_suspended(shared: Store) -> None:
    shared.suspend()

    shared.close()

    assert not shared.suspended


# MARK: - External changes


def test_checking_an_idle_store_for_external_changes_does_nothing(store: Store) -> None:
    store.set("theme", "dark")
    batches: list[ChangeBatch] = []
    store.subscribe(batches.append)

    store.check_for_external_changes()

    assert batches == []
    assert store.get("theme", str) == "dark"


def test_checking_an_idle_multi_process_store_for_external_changes_does_nothing(
    shared: Store,
) -> None:
    batches: list[ChangeBatch] = []
    shared.subscribe(batches.append)

    shared.check_for_external_changes()

    assert batches == []
    assert shared.get("theme", str) == "dark"


def test_an_open_temporary_store_is_single_process() -> None:
    with swiftmmkv.open_temporary() as store:
        assert store.configuration.mode is Mode.SINGLE_PROCESS
        store.suspend()
        assert not store.suspended
