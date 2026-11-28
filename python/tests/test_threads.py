"""A store used from several threads at once.

Every thread is joined with a timeout, and what a thread raises is raised again in the test."""

from __future__ import annotations

import gc
import threading
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor, wait
from typing import Any

import pytest

from swiftmmkv import ChangeBatch, Directory, Key, Mode, Store

THREADS = 8
#: How long any group of threads may take, in seconds.
TIMEOUT = 60.0


def run_together(*tasks: Callable[[], Any]) -> list[Any]:
    """Runs `tasks` on threads of their own, started together, and returns their results.

    What a task raises is raised here. A task that does not finish in time fails the test."""
    barrier = threading.Barrier(len(tasks))

    def started(task: Callable[[], Any]) -> Callable[[], Any]:
        def run() -> Any:
            barrier.wait(timeout=TIMEOUT)
            return task()

        return run

    with ThreadPoolExecutor(max_workers=len(tasks)) as executor:
        futures = [executor.submit(started(task)) for task in tasks]
        done, not_done = wait(futures, timeout=TIMEOUT)
        if not_done:
            barrier.abort()
            pytest.fail(f"{len(not_done)} threads did not finish in {TIMEOUT} seconds.")
        return [future.result() for future in futures]


def test_threads_writing_distinct_keys_lose_nothing(store: Store) -> None:
    def writer(thread: int) -> Callable[[], bool]:
        def write() -> bool:
            return all(store.set(f"{thread}.{index}", index) for index in range(200))

        return write

    results = run_together(*(writer(thread) for thread in range(THREADS)))

    assert all(results)
    assert len(store) == THREADS * 200
    assert all(
        store.get(f"{thread}.{index}", int) == index
        for thread in range(THREADS)
        for index in range(200)
    )


def test_threads_reading_and_writing_the_same_keys_read_only_what_was_written(
    store: Store,
) -> None:
    keys = [f"shared.{index}" for index in range(10)]
    written = {f"value {thread} {index}" for thread in range(THREADS) for index in range(100)}
    seen: list[set[str | None]] = []

    def writer(thread: int) -> Callable[[], None]:
        def write() -> None:
            for index in range(100):
                for key in keys:
                    assert store.set(key, f"value {thread} {index}")

        return write

    def reader() -> None:
        values: set[str | None] = set()
        for _ in range(300):
            for key in keys:
                values.add(store.get(key, str))
        seen.append(values)

    run_together(*(writer(thread) for thread in range(THREADS // 2)), *(reader for _ in range(4)))

    read = set().union(*seen) - {None}
    assert read <= written
    assert all(store.get(key, str) in written for key in keys)


def test_threads_read_whole_values_while_others_replace_them(store: Store) -> None:
    values = [bytes([thread]) * 4096 for thread in range(THREADS)]
    store.set("blob", values[0])
    torn: list[bytes] = []

    def writer(value: bytes) -> Callable[[], None]:
        def write() -> None:
            for _ in range(100):
                store.set("blob", value)

        return write

    def reader() -> None:
        for _ in range(400):
            value = store.get("blob", bytes)
            if value not in values:
                torn.append(value or b"")

    run_together(*(writer(value) for value in values[:4]), reader, reader)

    assert torn == []


def test_a_locked_read_modify_write_from_many_threads_loses_no_increment(store: Store) -> None:
    def increment() -> None:
        for _ in range(200):
            with store.locked():
                store.set("count", store.get("count", int, default=0) + 1)

    run_together(*(increment for _ in range(THREADS)))

    assert store.get("count", int) == THREADS * 200


def test_a_store_opened_on_one_thread_is_used_and_closed_on_another(
    directory: Directory,
) -> None:
    opened: list[Store] = []

    def open_store() -> None:
        store = directory.open(mode=Mode.SINGLE_PROCESS, id="settings")
        store.set("opened", "on another thread")
        opened.append(store)

    run_together(open_store)
    store = opened[0]

    def use_and_close() -> tuple[str | None, bool]:
        value = store.get("opened", str)
        store.set("used", "here")
        store.close()
        return value, store.closed

    assert run_together(use_and_close) == [("on another thread", True)]
    assert store.closed
    with directory.open(mode=Mode.SINGLE_PROCESS, id="settings") as reopened:
        assert reopened.keys() == {"opened", "used"}


def test_listeners_hear_changes_made_on_other_threads(store: Store) -> None:
    lock = threading.Lock()
    heard: list[str] = []

    def on_change(batch: ChangeBatch) -> None:
        with lock:
            heard.extend(batch.keys)

    subscription = store.subscribe(on_change)

    def writer(thread: int) -> Callable[[], None]:
        def write() -> None:
            for index in range(50):
                store.set(f"{thread}.{index}", index)

        return write

    run_together(*(writer(thread) for thread in range(THREADS)))
    subscription.cancel()

    assert sorted(heard) == sorted(f"{t}.{i}" for t in range(THREADS) for i in range(50))


def test_threads_subscribing_and_cancelling_while_others_write(store: Store) -> None:
    stop = threading.Event()
    lock = threading.Lock()
    heard: list[ChangeBatch] = []

    def on_change(batch: ChangeBatch) -> None:
        with lock:
            heard.append(batch)
        for key in batch.keys:
            batch.get(key, int)

    def subscriber() -> int:
        subscriptions = 0
        for index in range(100):
            if index % 2:
                subscription = store.subscribe(on_change, key="key.1")
            else:
                subscription = store.subscribe(on_change)
            subscription.cancel()
            subscription.cancel()
            assert subscription.cancelled
            subscriptions += 1
        return subscriptions

    def writer(thread: int) -> Callable[[], int]:
        def write() -> int:
            writes = 0
            while not stop.is_set() and writes < 100_000:
                store.set(f"key.{thread}", writes)
                writes += 1
            return writes

        return write

    def subscribers() -> list[int]:
        try:
            return run_together(*(subscriber for _ in range(4)))
        finally:
            stop.set()

    results = run_together(subscribers, *(writer(thread) for thread in range(4)))

    assert results[0] == [100] * 4
    assert all(writes > 0 for writes in results[1:])
    assert all(batch.keys or batch.is_external for batch in heard)


def test_a_listener_cancelled_on_another_thread_is_not_called_afterwards(store: Store) -> None:
    calls: list[tuple[str, ...]] = []
    subscription = store.subscribe(lambda batch: calls.append(batch.keys))
    store.set("before", 1)

    run_together(subscription.cancel)
    store.set("after", 1)

    assert calls == [("before",)]


def test_threads_each_opening_and_closing_their_own_store_over_the_same_files(
    directory: Directory,
) -> None:
    with directory.open(mode=Mode.SINGLE_PROCESS, id="settings") as store:
        store.set("theme", "dark")

    def open_and_close(thread: int) -> Callable[[], str | None]:
        def run() -> str | None:
            last = None
            for index in range(20):
                store = directory.open(mode=Mode.SINGLE_PROCESS, id="settings")
                last = store.get("theme", str) if not store.closed else None
                store.set(f"{thread}.{index}", index)
                store.close()
                assert store.closed
            return last

        return run

    results = run_together(*(open_and_close(thread) for thread in range(THREADS)))

    assert all(result in ("dark", None) for result in results)
    with directory.open(mode=Mode.SINGLE_PROCESS, id="settings") as store:
        assert store.get("theme", str) == "dark"
        assert set(store.keys()) <= {"theme"} | {
            f"{t}.{i}" for t in range(THREADS) for i in range(20)
        }
    assert directory.remove_store("settings")


def test_threads_each_opening_a_store_and_letting_go_of_it(directory: Directory) -> None:
    key = Key("count", int)

    def open_and_drop(thread: int) -> Callable[[], None]:
        def run() -> None:
            for index in range(20):
                store = directory.open(mode=Mode.SINGLE_PROCESS, id="settings")
                assert store.set(key, thread * 100 + index)
                del store
                gc.collect()

        return run

    run_together(*(open_and_drop(thread) for thread in range(4)))

    with directory.open(mode=Mode.SINGLE_PROCESS, id="settings") as store:
        assert store.get(key) is not None


def test_closing_while_other_threads_use_the_store_is_safe(directory: Directory) -> None:
    store = directory.open(mode=Mode.SINGLE_PROCESS, id="settings")
    store.set("key", "value")
    started = threading.Event()

    def user() -> set[str | None]:
        seen: set[str | None] = set()
        for index in range(2000):
            if index == 10:
                started.set()
            store.set("key", "value")
            seen.add(store.get("key", str))
        return seen

    def closer() -> None:
        assert started.wait(timeout=TIMEOUT)
        store.close()

    results = run_together(user, user, user, closer)

    assert store.closed
    assert all(seen <= {"value", None} for seen in results[:3])
    assert store.get("key", str) is None
