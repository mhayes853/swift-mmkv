"""A directory of stores, what it does to its stores without opening them, and backups."""

from __future__ import annotations

import os
import pickle
from collections.abc import Iterator
from pathlib import Path

import pytest

from swiftmmkv import ChangeBatch, Directory, MMKVError, Mode, Status, Store, StoreID


@pytest.fixture
def opened() -> Iterator[list[Store]]:
    """The stores a test opens, which are closed after it."""
    stores: list[Store] = []
    yield stores
    for store in stores:
        store.close()


def open_in(opened: list[Store], directory: Directory, id: str = "settings") -> Store:
    store = directory.open(mode=Mode.SINGLE_PROCESS, id=id)
    opened.append(store)
    return store


def write_closed(directory: Directory, id: str, **values: str) -> None:
    """Writes a store and closes it."""
    with directory.open(mode=Mode.SINGLE_PROCESS, id=id) as store:
        for key, value in values.items():
            store.set(key, value)


def read_closed(directory: Directory, id: str, key: str) -> str | None:
    """Reads a value from a store, which is closed again afterwards."""
    with directory.open(mode=Mode.SINGLE_PROCESS, id=id) as store:
        return store.get(key, str)


# MARK: - The directory as a path


def test_a_directory_is_its_path(tmp_path: Path) -> None:
    directory = Directory(str(tmp_path))

    assert directory.path == str(tmp_path)
    assert os.fspath(directory) == str(tmp_path)


def test_a_directory_takes_a_pathlib_path(tmp_path: Path) -> None:
    directory = Directory(tmp_path / "mmkv")

    assert directory.path == str(tmp_path / "mmkv")
    assert isinstance(directory.path, str)


def test_a_directory_takes_another_directory(tmp_path: Path) -> None:
    assert Directory(Directory(tmp_path)).path == str(tmp_path)


def test_a_directory_path_is_text(tmp_path: Path) -> None:
    with pytest.raises(TypeError):
        Directory(os.fsencode(tmp_path))  # type: ignore[arg-type]


def test_making_a_directory_touches_no_file(tmp_path: Path) -> None:
    Directory(tmp_path / "mmkv")

    assert not (tmp_path / "mmkv").exists()


def test_directories_are_equal_when_their_paths_are(tmp_path: Path) -> None:
    assert Directory(tmp_path) == Directory(str(tmp_path))
    assert Directory(tmp_path) != Directory(tmp_path / "other")
    assert Directory(tmp_path) != str(tmp_path)


def test_equal_directories_hash_alike(tmp_path: Path) -> None:
    assert hash(Directory(tmp_path)) == hash(Directory(str(tmp_path)))
    assert len({Directory(tmp_path), Directory(str(tmp_path)), Directory(tmp_path / "a")}) == 2


def test_a_directory_repr_is_its_path() -> None:
    assert repr(Directory("/var/lib/mmkv")) == "Directory('/var/lib/mmkv')"


def test_a_directory_pickles(tmp_path: Path) -> None:
    assert pickle.loads(pickle.dumps(Directory(tmp_path))) == Directory(tmp_path)


def test_a_directory_is_taken_where_a_path_is(directory: Directory) -> None:
    directory.open(mode=Mode.SINGLE_PROCESS).close()

    assert Path(directory).is_dir()


def test_a_temporary_directory_is_new_each_time() -> None:
    first, second = Directory.temporary(), Directory.temporary()

    assert first != second
    assert os.path.isabs(first.path)


def test_a_temporary_directory_holds_stores() -> None:
    directory = Directory.temporary()
    with directory.open(mode=Mode.SINGLE_PROCESS) as store:
        store.set("key", "value")

    assert directory.contains_store()
    assert directory.remove_all_stores() == 1


# MARK: - Opening


def test_a_directory_opens_its_stores(directory: Directory, opened: list[Store]) -> None:
    store = open_in(opened, directory, "settings")

    assert store.directory == directory
    assert store.id == StoreID("settings")
    assert store.configuration.mode is Mode.SINGLE_PROCESS
    assert store.set("key", "value")


def test_a_directory_opens_the_default_store(directory: Directory) -> None:
    with directory.open(mode=Mode.SINGLE_PROCESS) as store:
        assert store.id == StoreID.DEFAULT

    assert directory.contains_store(StoreID.DEFAULT)


def test_a_directory_opens_with_the_options_of_open(directory: Directory) -> None:
    write_closed(directory, "settings", key="value")

    with directory.open(mode=Mode.SINGLE_PROCESS, id="settings", read_only=True) as store:
        assert store.configuration.read_only
        assert store.set("key", "other") is False
        assert store.get("key", str) == "value"


def test_a_directory_is_created_when_a_store_in_it_is_opened(directory: Directory) -> None:
    with directory.open(mode=Mode.SINGLE_PROCESS):
        assert os.path.isdir(directory)


# MARK: - Its stores


def test_a_directory_holds_a_store_once_it_is_opened(
    directory: Directory, opened: list[Store]
) -> None:
    assert not directory.contains_store("settings")

    open_in(opened, directory, "settings")

    assert directory.contains_store("settings")
    assert not directory.contains_store("other")


def test_a_directory_that_does_not_exist_holds_no_store(tmp_path: Path) -> None:
    directory = Directory(tmp_path / "missing")

    assert not directory.contains_store()
    assert not directory.is_store_valid()


def test_a_written_store_is_valid(directory: Directory) -> None:
    write_closed(directory, "settings", key="value")

    assert directory.is_store_valid("settings")


def test_a_store_that_does_not_exist_is_not_valid(directory: Directory) -> None:
    write_closed(directory, "settings", key="value")

    assert not directory.is_store_valid("other")


def test_a_damaged_store_is_not_valid(directory: Directory) -> None:
    write_closed(directory, "settings", key="value")
    with open(os.path.join(directory, "settings"), "r+b") as file:
        file.seek(4)
        file.write(b"\xff" * 8)

    assert not directory.is_store_valid("settings")


def test_removing_a_store_deletes_its_files(directory: Directory) -> None:
    write_closed(directory, "settings", key="value")
    write_closed(directory, "other", key="value")

    assert directory.remove_store("settings") is True

    assert not directory.contains_store("settings")
    assert directory.contains_store("other")
    assert read_closed(directory, "settings", "key") is None


def test_removing_a_store_that_has_no_files_says_so(directory: Directory) -> None:
    assert directory.remove_store("settings") is False


def test_removing_a_store_that_is_open_is_refused(
    directory: Directory, opened: list[Store]
) -> None:
    store = open_in(opened, directory, "settings")
    store.set("key", "value")

    with pytest.raises(MMKVError) as caught:
        directory.remove_store("settings")

    assert caught.value.status is Status.STORE_IS_OPEN
    assert directory.contains_store("settings")
    assert store.get("key", str) == "value"


def test_removing_every_store_counts_them(directory: Directory) -> None:
    for id in ("first", "second", "third"):
        write_closed(directory, id, key="value")

    assert directory.remove_all_stores() == 3

    assert not any(directory.contains_store(id) for id in ("first", "second", "third"))


def test_removing_every_store_of_an_empty_directory_removes_none(
    directory: Directory, tmp_path: Path
) -> None:
    assert Directory(tmp_path / "missing").remove_all_stores() == 0
    os.makedirs(directory)
    assert directory.remove_all_stores() == 0


def test_removing_every_store_leaves_the_open_ones(
    directory: Directory, opened: list[Store]
) -> None:
    write_closed(directory, "closed", key="value")
    open_in(opened, directory, "open").set("key", "value")

    with pytest.raises(MMKVError) as caught:
        directory.remove_all_stores()

    assert caught.value.status is Status.STORES_ARE_OPEN
    assert not directory.contains_store("closed")
    assert directory.contains_store("open")


# MARK: - Backups through the directory


def test_a_directory_backs_up_a_store_that_is_not_open(
    directory: Directory, tmp_path: Path
) -> None:
    write_closed(directory, "settings", theme="dark")
    backup = Directory(tmp_path / "backup")

    assert directory.back_up_store("settings", backup) is True

    assert backup.contains_store("settings")
    assert read_closed(backup, "settings", "theme") == "dark"


def test_a_directory_backs_up_a_store_that_is_open(
    directory: Directory, opened: list[Store], tmp_path: Path
) -> None:
    open_in(opened, directory, "settings").set("theme", "dark")

    assert directory.back_up_store("settings", tmp_path / "backup") is True

    assert read_closed(Directory(tmp_path / "backup"), "settings", "theme") == "dark"


def test_a_store_that_does_not_exist_is_not_backed_up(directory: Directory, tmp_path: Path) -> None:
    assert directory.back_up_store("missing", tmp_path / "backup") is False


def test_a_directory_restores_a_store_that_is_not_open(
    directory: Directory, tmp_path: Path
) -> None:
    write_closed(directory, "settings", theme="dark")
    directory.back_up_store("settings", tmp_path / "backup")
    write_closed(directory, "settings", theme="light", extra="1")

    assert directory.restore_store("settings", tmp_path / "backup") is True

    assert read_closed(directory, "settings", "theme") == "dark"
    assert read_closed(directory, "settings", "extra") is None


def test_a_directory_restores_into_another_directory(directory: Directory, tmp_path: Path) -> None:
    write_closed(directory, "settings", theme="dark")
    directory.back_up_store("settings", tmp_path / "backup")
    restored = Directory(tmp_path / "restored")

    assert restored.restore_store("settings", tmp_path / "backup") is True

    assert read_closed(restored, "settings", "theme") == "dark"


def test_a_backup_without_the_store_restores_nothing(directory: Directory, tmp_path: Path) -> None:
    write_closed(directory, "settings", theme="dark")

    assert directory.restore_store("settings", tmp_path / "missing") is False

    assert read_closed(directory, "settings", "theme") == "dark"


def test_a_directory_restores_over_an_open_store(
    directory: Directory, opened: list[Store], tmp_path: Path
) -> None:
    store = open_in(opened, directory, "settings")
    store.set("theme", "dark")
    directory.back_up_store("settings", tmp_path / "backup")
    store.set("theme", "light")

    assert directory.restore_store("settings", tmp_path / "backup") is True

    assert store.get("theme", str) == "dark"


def test_a_directory_restore_tells_listeners_of_an_external_change(
    directory: Directory, opened: list[Store], tmp_path: Path
) -> None:
    store = open_in(opened, directory, "settings")
    store.set("theme", "dark")
    directory.back_up_store("settings", tmp_path / "backup")
    batches: list[ChangeBatch] = []
    store.subscribe(batches.append)

    directory.restore_store("settings", tmp_path / "backup")

    assert [(batch.keys, batch.is_external) for batch in batches] == [((), True)]


def test_every_store_is_backed_up_and_counted(directory: Directory, tmp_path: Path) -> None:
    for id in ("first", "second", "third"):
        write_closed(directory, id, key=id)
    backup = Directory(tmp_path / "backup")

    assert directory.back_up_all_stores(backup) == 3

    assert all(read_closed(backup, id, "key") == id for id in ("first", "second", "third"))


def test_every_store_is_restored_and_counted(
    directory: Directory, opened: list[Store], tmp_path: Path
) -> None:
    write_closed(directory, "closed", key="first")
    store = open_in(opened, directory, "open")
    store.set("key", "first")
    directory.back_up_all_stores(tmp_path / "backup")
    write_closed(directory, "closed", key="second")
    store.set("key", "second")

    assert directory.restore_all_stores(tmp_path / "backup") == 2

    assert read_closed(directory, "closed", "key") == "first"
    assert store.get("key", str) == "first"


def test_an_empty_directory_backs_up_and_restores_none(
    directory: Directory, tmp_path: Path
) -> None:
    assert directory.back_up_all_stores(tmp_path / "backup") == 0
    assert directory.restore_all_stores(tmp_path / "missing") == 0


# MARK: - Backups through the store


def test_a_store_backs_up_into_a_directory_of_stores(store: Store, tmp_path: Path) -> None:
    store.set("theme", "dark")

    store.back_up(tmp_path / "backup")

    backup = Directory(tmp_path / "backup")
    assert backup.contains_store(store.id)
    assert read_closed(backup, store.id, "theme") == "dark"


def test_a_store_back_up_returns_nothing(store: Store, tmp_path: Path) -> None:
    store.set("theme", "dark")

    assert store.back_up(tmp_path / "backup") is None  # type: ignore[func-returns-value]


def test_a_store_restore_replaces_its_contents(store: Store, tmp_path: Path) -> None:
    store.set("theme", "dark")
    store.back_up(tmp_path / "backup")
    store.set("theme", "light")
    store.set("extra", 1.0)

    assert store.restore(tmp_path / "backup") is True

    assert store.get("theme", str) == "dark"
    assert "extra" not in store
    assert store.keys() == {"theme"}


def test_a_store_restore_from_a_backup_without_it_says_so(store: Store, tmp_path: Path) -> None:
    store.set("theme", "light")
    os.makedirs(tmp_path / "empty")

    assert store.restore(tmp_path / "empty") is False

    assert store.get("theme", str) == "light"


def test_a_later_backup_replaces_an_earlier_one(store: Store, tmp_path: Path) -> None:
    store.set("theme", "dark")
    store.back_up(tmp_path / "backup")
    store.set("theme", "light")
    store.back_up(tmp_path / "backup")
    store.clear()

    store.restore(tmp_path / "backup")

    assert store.get("theme", str) == "light"


def test_a_store_restore_tells_listeners_of_an_external_change(
    store: Store, tmp_path: Path
) -> None:
    store.set("theme", "dark")
    store.back_up(tmp_path / "backup")
    batches: list[ChangeBatch] = []
    store.subscribe(batches.append)

    store.restore(tmp_path / "backup")

    assert [(batch.keys, batch.is_external) for batch in batches] == [((), True)]


def test_a_store_restore_shows_in_another_store_over_its_files(
    directory: Directory, opened: list[Store], tmp_path: Path
) -> None:
    first = open_in(opened, directory, "settings")
    second = open_in(opened, directory, "settings")
    first.set("theme", "dark")
    first.back_up(tmp_path / "backup")
    first.set("theme", "light")

    first.restore(tmp_path / "backup")

    assert second.get("theme", str) == "dark"
