"""Closing is explicit, a closed store stays usable, and letting go of a store frees its
handle without closing it."""

from __future__ import annotations

import gc
from collections.abc import Callable, Iterator
from datetime import timedelta
from pathlib import Path
from typing import Any

import pytest

import swiftmmkv
from swiftmmkv import ChangeBatch, Directory, Encryption, Key, MMKVError, Mode, Status, Store

NAME = Key("name", str)
VOLUME = Key("volume", float, default=0.5)


@pytest.fixture
def closed(directory: Directory) -> Iterator[Store]:
    """A store that held values when it was closed."""
    store = directory.open(mode=Mode.SINGLE_PROCESS, id="settings")
    store.set("theme", "dark")
    store.set("count", 3)
    store.set("tags", ["a", "b"])
    store.set(NAME, "blob")
    store.set(VOLUME, 0.8)
    store.back_up(directory.path + "-backup")
    store.close()
    yield store
    directory.remove_all_stores()


def test_a_store_is_open_until_it_is_closed(store: Store) -> None:
    assert not store.closed

    store.close()

    assert store.closed


def test_a_closed_store_reads_nothing(closed: Store) -> None:
    assert closed.get("theme", str) is None
    assert closed.get("count", int) is None
    assert closed.get("tags", list[str]) is None
    assert closed.get("theme", str, default="light") == "light"
    assert closed.get_many(["theme", "count"], str) == {}


def test_a_closed_store_has_no_keys(closed: Store) -> None:
    assert "theme" not in closed
    assert NAME not in closed
    assert len(closed) == 0
    assert list(closed) == []
    assert closed.keys() == frozenset()
    assert closed.keys(under="") == frozenset()


def test_a_closed_store_has_no_value_sizes(closed: Store) -> None:
    assert closed.value_size("theme") is None


def test_a_closed_store_reads_typed_keys_as_missing(closed: Store) -> None:
    assert closed.get(NAME) is None
    assert closed.get(VOLUME) == 0.5
    with pytest.raises(KeyError):
        closed[NAME]


def test_a_closed_store_writes_nothing_and_says_so(closed: Store) -> None:
    assert closed.set("theme", "light") is False
    assert closed.set("count", 4, swiftmmkv.int32) is False
    assert closed.set(NAME, "other") is False
    assert closed.set("otp", "1", expiry=timedelta(hours=1)) is False
    assert closed.set_many({"a": 1, "b": 2}) is False
    closed[NAME] = "other"

    assert len(closed) == 0
    assert closed.get("theme", str) is None


def test_a_closed_store_removes_nothing(closed: Store, directory: Directory) -> None:
    assert closed.remove("theme") is False
    closed.remove_many(["theme", "count"])
    closed.remove_under("")
    closed.clear()
    closed.clear(keep_capacity=True)
    del closed["theme"]

    with directory.open(mode=Mode.SINGLE_PROCESS, id="settings") as reopened:
        assert reopened.keys() == {"theme", "count", "tags", "name", "volume"}


def test_a_closed_store_imports_nothing(closed: Store, store: Store) -> None:
    store.set("key", "value")

    assert closed.import_all(store) == 0
    assert store.import_all(closed) == 0
    assert store.keys() == {"key"}


def test_a_closed_store_raises_nothing_for_its_maintenance(closed: Store) -> None:
    closed.trim()
    closed.sync()
    closed.release_memory()
    closed.check_for_external_changes()
    closed.suspend()
    closed.resume()

    assert closed.byte_size == 0
    assert closed.used_byte_size == 0
    assert not closed.expiry_enabled
    assert not closed.suspended


def test_a_closed_store_can_be_locked_and_turns_away_what_the_block_does(
    closed: Store,
) -> None:
    with closed.locked():
        assert closed.set("theme", "light") is False
        assert closed.get("theme", str) is None


def test_a_closed_store_takes_listeners_that_hear_nothing(closed: Store) -> None:
    batches: list[ChangeBatch] = []
    values: list[str | None] = []

    with closed.subscribe(batches.append), closed.observe("theme", str, values.append):
        closed.set("theme", "light")

    assert batches == []
    assert values == [None]


@pytest.mark.parametrize(
    "operation",
    [
        lambda store, backup: store.rekey(Encryption.aes128("secret")),
        lambda store, backup: store.rekey(None),
        lambda store, backup: store.disable_expiry(),
        lambda store, backup: store.back_up(backup),
        lambda store, backup: store.restore(backup),
    ],
    ids=["rekey", "decrypt", "disable_expiry", "back_up", "restore"],
)
def test_what_reports_a_status_raises_store_is_closed(
    closed: Store, directory: Directory, operation: Callable[[Store, str], Any]
) -> None:
    with pytest.raises(MMKVError) as caught:
        operation(closed, directory.path + "-backup")

    assert caught.value.status is Status.STORE_IS_CLOSED


def test_closing_twice_is_harmless(store: Store) -> None:
    store.close()
    store.close()

    assert store.closed


def test_a_with_block_closes_the_store(directory: Directory) -> None:
    with swiftmmkv.open(directory, mode=Mode.SINGLE_PROCESS) as store:
        store.set("key", "value")
        assert not store.closed

    assert store.closed
    assert directory.remove_store()


def test_a_with_block_closes_the_store_when_it_raises(directory: Directory) -> None:
    with pytest.raises(ZeroDivisionError):
        with swiftmmkv.open(directory, mode=Mode.SINGLE_PROCESS) as store:
            store.set("key", "value")
            raise ZeroDivisionError

    assert store.closed
    assert directory.remove_store()


def test_a_with_block_gives_the_store_it_was_entered_with(store: Store) -> None:
    with store as entered:
        assert entered is store


def test_closing_closes_every_store_over_the_same_files(directory: Directory) -> None:
    first = directory.open(mode=Mode.SINGLE_PROCESS, id="settings")
    second = directory.open(mode=Mode.SINGLE_PROCESS, id="settings")
    second.set("key", "value")

    first.close()

    assert second.closed
    assert second.get("key", str) is None
    assert second.set("key", "other") is False


def test_closing_leaves_a_store_over_other_files_open(directory: Directory) -> None:
    first = directory.open(mode=Mode.SINGLE_PROCESS, id="first")
    second = directory.open(mode=Mode.SINGLE_PROCESS, id="second")
    second.set("key", "value")

    first.close()

    assert not second.closed
    assert second.get("key", str) == "value"
    second.close()


def test_closing_tells_listeners_once_of_an_external_change(store: Store) -> None:
    batches: list[ChangeBatch] = []
    store.subscribe(batches.append)
    store.set("key", "value")
    batches.clear()

    store.close()
    store.set("key", "other")

    assert [(batch.keys, batch.is_external) for batch in batches] == [((), True)]


def test_a_closed_store_opened_again_reads_its_files(directory: Directory) -> None:
    store = directory.open(mode=Mode.SINGLE_PROCESS, id="settings")
    store.set("key", "value")
    store.close()

    with directory.open(mode=Mode.SINGLE_PROCESS, id="settings") as reopened:
        assert not reopened.closed
        assert reopened.get("key", str) == "value"
        assert store.closed


def test_a_closed_store_opened_again_reads_its_files_as_they_then_are(
    directory: Directory, tmp_path: Path
) -> None:
    store = directory.open(mode=Mode.SINGLE_PROCESS, id="settings")
    store.set("theme", "dark")
    store.back_up(tmp_path / "backup")
    store.set("theme", "light")
    store.close()
    assert directory.restore_store("settings", tmp_path / "backup")

    with directory.open(mode=Mode.SINGLE_PROCESS, id="settings") as reopened:
        assert reopened.get("theme", str) == "dark"


def test_a_closed_store_can_be_removed(directory: Directory) -> None:
    store = directory.open(mode=Mode.SINGLE_PROCESS, id="settings")
    store.set("key", "value")

    store.close()

    assert directory.remove_store("settings")
    assert not directory.contains_store("settings")


def test_letting_go_of_a_store_leaves_another_over_its_files_working(
    directory: Directory,
) -> None:
    kept = directory.open(mode=Mode.SINGLE_PROCESS, id="settings")
    dropped = directory.open(mode=Mode.SINGLE_PROCESS, id="settings")
    dropped.set("key", "value")

    del dropped
    gc.collect()

    assert not kept.closed
    assert kept.get("key", str) == "value"
    assert kept.set("key", "other")
    kept.close()


def test_letting_go_of_the_last_store_does_not_close_it(directory: Directory) -> None:
    store = directory.open(mode=Mode.SINGLE_PROCESS, id="settings")
    store.set("key", "value")

    del store
    gc.collect()

    with pytest.raises(MMKVError) as caught:
        directory.remove_store("settings")
    assert caught.value.status is Status.STORE_IS_OPEN
    with directory.open(mode=Mode.SINGLE_PROCESS, id="settings") as reopened:
        assert reopened.get("key", str) == "value"
    assert directory.remove_store("settings")


def test_a_store_is_not_made_by_calling_its_class() -> None:
    with pytest.raises(TypeError):
        Store()


def test_a_store_repr_names_its_identifier_and_directory(directory: Directory) -> None:
    store = directory.open(mode=Mode.SINGLE_PROCESS, id="settings")

    assert repr(store) == f"<swiftmmkv.Store 'settings' in {directory.path!r}>"
    store.close()
    assert repr(store) == f"<swiftmmkv.Store 'settings' in {directory.path!r} closed>"
