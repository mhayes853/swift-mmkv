"""`Store.locked`: exclusive access to a store for the length of a block."""

from __future__ import annotations

import functools
import threading
from collections.abc import Callable, Iterator
from pathlib import Path
from uuid import uuid4

import pytest

import swiftmmkv
from swiftmmkv import ChangeBatch, Mode, Store

TIMEOUT = 5.0


@pytest.fixture
def shared(store: Store) -> Iterator[Store]:
    """A second `Store` over the files of `store`."""
    second = swiftmmkv.open(store.configuration)
    yield second
    second.close()


@pytest.fixture
def multi_process(tmp_path: Path) -> Iterator[Store]:
    """A multi-process store, which is the only kind suspension does anything for."""
    store = swiftmmkv.open(tmp_path / "mmkv", mode=Mode.MULTI_PROCESS, id=f"lock-{uuid4().hex}")
    yield store
    store.resume()
    store.close()


def start(target: Callable[[], object]) -> threading.Thread:
    thread = threading.Thread(target=target, daemon=True)
    thread.start()
    return thread


def finish(thread: threading.Thread) -> None:
    thread.join(TIMEOUT)
    assert not thread.is_alive()


class Boom(Exception):
    pass


def test_a_locked_block_does_a_read_modify_write(store: Store) -> None:
    store.set("launches", 2)

    with store.locked():
        launches = store.get("launches", int, default=0)
        store.set("launches", launches + 1)

    assert store.get("launches", int) == 3


def test_listeners_hear_nothing_during_a_locked_block(store: Store) -> None:
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append), store.locked():
        store.set("a", 1)
        store.set("b", 2)
        store.remove("a")
        assert batches == []


def test_listeners_hear_of_a_locked_block_once_it_is_left(store: Store) -> None:
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append):
        with store.locked():
            store.set("a", 1)
            store.set("b", 2)

        assert len(batches) == 1
        assert sorted(batches[0].keys) == ["a", "b"]
        assert not batches[0].is_external


def test_a_locked_block_tells_listeners_of_each_key_once(store: Store) -> None:
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append):
        with store.locked():
            store.set("a", 1)
            store.set("b", 2)
            store.set("a", 3)
            store.remove("b")

        assert len(batches) == 1
        assert sorted(batches[0].keys) == ["a", "b"]


def test_listeners_see_every_value_a_locked_block_wrote(store: Store) -> None:
    seen: list[tuple[int | None, int | None]] = []
    with store.subscribe(lambda batch: seen.append((batch.get("x", int), batch.get("y", int)))):
        with store.locked():
            store.set("x", 1)
            store.set("y", 2)

    assert seen == [(1, 2)]


def test_a_locked_block_that_writes_nothing_tells_listeners_nothing(store: Store) -> None:
    store.set("a", 1)
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append):
        with store.locked():
            assert store.get("a", int) == 1

        assert batches == []


def test_locked_blocks_nest(store: Store) -> None:
    with store.locked():
        store.set("a", 1)
        with store.locked():
            store.set("b", 2)
        store.set("c", 3)

    assert (store.get("a", int), store.get("b", int), store.get("c", int)) == (1, 2, 3)


def test_listeners_hear_of_nested_blocks_after_the_outermost(store: Store) -> None:
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append):
        with store.locked():
            store.set("a", 1)
            with store.locked():
                store.set("b", 2)
            assert batches == []
            store.set("c", 3)
        assert len(batches) == 1
        assert sorted(batches[0].keys) == ["a", "b", "c"]


def test_one_locked_context_manager_can_be_entered_again_inside_itself(store: Store) -> None:
    lock = store.locked()
    with lock:
        with lock:
            store.set("a", 1)
        store.set("b", 2)

    assert (store.get("a", int), store.get("b", int)) == (1, 2)
    # Given up both times, so closing is allowed.
    store.close()
    assert store.closed


def test_an_exception_raised_in_a_locked_block_comes_out_of_the_with(store: Store) -> None:
    with pytest.raises(Boom), store.locked():
        raise Boom


def test_a_locked_block_gives_up_the_lock_when_it_raises(store: Store) -> None:
    with pytest.raises(Boom), store.locked():
        raise Boom

    written = threading.Event()

    def write() -> None:
        store.set("a", 1)
        written.set()

    finish(start(write))
    assert written.is_set()
    store.close()
    assert store.closed


def test_keys_written_before_a_locked_block_raises_stay_written(store: Store) -> None:
    with pytest.raises(Boom), store.locked():
        store.set("a", 1)
        raise Boom

    assert store.get("a", int) == 1


def test_listeners_hear_of_keys_written_before_a_locked_block_raised(store: Store) -> None:
    batches: list[ChangeBatch] = []
    with store.subscribe(batches.append):
        with pytest.raises(Boom), store.locked():
            store.set("a", 1)
            raise Boom

        assert [batch.keys for batch in batches] == [("a",)]


def test_another_threads_write_waits_until_the_locked_block_is_left(store: Store) -> None:
    started, written = threading.Event(), threading.Event()

    def write() -> None:
        started.set()
        store.set("a", 2)
        written.set()

    with store.locked():
        store.set("a", 1)
        thread = start(write)
        assert started.wait(TIMEOUT)
        assert not written.wait(0.2)
        assert store.get("a", int) == 1

    finish(thread)
    assert written.is_set()
    assert store.get("a", int) == 2


def test_another_threads_read_waits_until_the_locked_block_is_left(store: Store) -> None:
    store.set("a", 1)
    started = threading.Event()
    read: list[int | None] = []

    def reader() -> None:
        started.set()
        read.append(store.get("a", int))

    with store.locked():
        thread = start(reader)
        assert started.wait(TIMEOUT)
        thread.join(0.2)
        assert thread.is_alive()
        store.set("a", 2)

    finish(thread)
    assert read == [2]


def test_a_block_entered_through_one_store_holds_off_writes_through_another(
    store: Store, shared: Store
) -> None:
    started, written = threading.Event(), threading.Event()

    def write() -> None:
        started.set()
        store.set("a", 1)
        written.set()

    with shared.locked():
        thread = start(write)
        assert started.wait(TIMEOUT)
        assert not written.wait(0.2)

    finish(thread)
    assert shared.get("a", int) == 1


def test_closing_inside_a_locked_block_raises_and_does_not_close(store: Store) -> None:
    with store.locked():
        with pytest.raises(RuntimeError):
            store.close()
        assert not store.closed
        assert store.set("a", 1)

    assert not store.closed
    assert store.get("a", int) == 1


def test_closing_inside_a_nested_block_raises_after_the_inner_block_is_left(
    store: Store,
) -> None:
    with store.locked():
        with store.locked():
            pass
        with pytest.raises(RuntimeError):
            store.close()

    assert not store.closed


def test_a_store_can_be_closed_once_its_locked_block_is_left(store: Store) -> None:
    with store.locked():
        store.set("a", 1)

    store.close()
    assert store.closed


def test_closing_inside_a_block_entered_through_another_store_raises(
    store: Store, shared: Store
) -> None:
    with shared.locked():
        with pytest.raises(RuntimeError):
            store.close()
        assert not store.closed
        assert not shared.closed

    assert not store.closed


def test_suspending_inside_a_locked_block_raises_and_does_not_suspend(
    multi_process: Store,
) -> None:
    with multi_process.locked():
        with pytest.raises(RuntimeError):
            multi_process.suspend()
        assert not multi_process.suspended
        assert multi_process.set("a", 1)

    assert not multi_process.suspended
    assert multi_process.get("a", int) == 1


def test_suspending_inside_a_block_entered_through_another_store_raises(
    multi_process: Store,
) -> None:
    second = swiftmmkv.open(multi_process.configuration)
    try:
        with second.locked():
            with pytest.raises(RuntimeError):
                multi_process.suspend()
            assert not multi_process.suspended
            assert not second.suspended
    finally:
        second.close()


def test_another_thread_can_close_a_store_once_this_thread_leaves_its_block(
    store: Store,
) -> None:
    started, closed = threading.Event(), threading.Event()

    def close() -> None:
        started.set()
        store.close()
        closed.set()

    with store.locked():
        thread = start(close)
        assert started.wait(TIMEOUT)
        assert not closed.wait(0.2)

    finish(thread)
    assert store.closed


def test_a_listener_told_of_a_locked_block_may_close_the_store(store: Store) -> None:
    def close(batch: ChangeBatch) -> None:
        if not batch.is_external:
            batch.store.close()

    with store.subscribe(close):
        with store.locked():
            store.set("a", 1)

    assert store.closed


def test_leaving_a_locked_block_on_another_thread_raises(store: Store) -> None:
    lock = store.locked()
    lock.__enter__()
    errors: list[BaseException] = []

    def leave() -> None:
        try:
            lock.__exit__(None, None, None)
        except BaseException as error:
            errors.append(error)

    try:
        finish(start(leave))
        assert len(errors) == 1
        assert isinstance(errors[0], RuntimeError)
    finally:
        lock.__exit__(None, None, None)

    # The thread that entered still held the lock, and gave it up above.
    store.close()
    assert store.closed


def test_a_lock_left_on_the_wrong_thread_is_still_held(store: Store) -> None:
    lock = store.locked()
    lock.__enter__()
    try:
        failed = threading.Event()

        def leave() -> None:
            try:
                lock.__exit__(None, None, None)
            except RuntimeError:
                failed.set()

        finish(start(leave))
        assert failed.is_set()

        written = threading.Event()
        thread = start(lambda: (store.set("a", 1), written.set()))
        assert not written.wait(0.2)
    finally:
        lock.__exit__(None, None, None)

    finish(thread)
    assert written.is_set()


def test_a_locked_block_on_a_closed_store_takes_nothing(store: Store) -> None:
    store.close()
    done = threading.Event()

    def use() -> None:
        store.set("a", 1)
        store.get("a", int)
        done.set()

    with store.locked():
        finish(start(use))

    assert done.is_set()


def test_operations_in_a_locked_block_on_a_closed_store_are_turned_away(store: Store) -> None:
    store.set("a", 1)
    store.close()

    with store.locked():
        assert not store.set("b", 2)
        assert store.get("a", int) is None
        assert store.get("b", int) is None
        assert len(store) == 0


def test_threads_incrementing_under_the_lock_lose_no_update(store: Store) -> None:
    threads, increments = 8, 200
    barrier = threading.Barrier(threads, timeout=TIMEOUT)

    def increment() -> None:
        barrier.wait()
        for _ in range(increments):
            with store.locked():
                store.set("count", store.get("count", int, default=0) + 1)

    workers = [start(increment) for _ in range(threads)]
    for worker in workers:
        worker.join(30)
        assert not worker.is_alive()

    assert store.get("count", int) == threads * increments


def test_threads_incrementing_under_locks_of_two_stores_lose_no_update(
    store: Store, shared: Store
) -> None:
    increments = 300
    barrier = threading.Barrier(2, timeout=TIMEOUT)

    def increment(through: Store) -> None:
        barrier.wait()
        for _ in range(increments):
            with through.locked():
                through.set("count", through.get("count", int, default=0) + 1)

    workers = [start(functools.partial(increment, through)) for through in (store, shared)]
    for worker in workers:
        worker.join(30)
        assert not worker.is_alive()

    assert store.get("count", int) == 2 * increments
