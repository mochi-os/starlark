#!/usr/bin/env python3
# Copyright © 2026 Mochisoft OÜ
# SPDX-License-Identifier: Apache-2.0

"""Interleavings of attachments.star no request can be timed to reach: the
library's source is run as Python, which its syntax allows (check.py parses it
so), against a scripted mochi that records every call."""
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parent.parent / "attachments.star"


class Mochi:
    """A mochi whose handlers are scripted by path; every other call is
    recorded and answers None."""

    def __init__(self, handlers):
        self.handlers = handlers
        self.calls = []

    def namespace(self, path):
        fake = self

        class Namespace:
            def __getattr__(self, name):
                return fake.namespace(path + "." + name)

            def __call__(self, *args, **kwargs):
                fake.calls.append(path)
                handler = fake.handlers.get(path)
                return handler(*args) if handler else None

        return Namespace()


def library(mochi):
    scope = {"mochi": mochi.namespace("mochi")}
    exec(compile(SOURCE.read_text(encoding="utf-8"), str(SOURCE), "exec"), scope)
    return scope


class Store:
    """One user's attachment row and cache, as two requests share them."""

    def __init__(self, cached):
        self.row = {"id": "a1", "object": "post/1", "entity": "remote", "name": "photo.jpg",
                    "content_type": "image/jpeg", "size": 632}
        self.cache = set()
        self.reads = 0
        self.adopted = None
        handlers = {
            "mochi.db.row": self.read,
            "mochi.cache.path": lambda name: name if name in self.cache else None,
            # Nothing else is transferring: the wait answers what is there.
            "mochi.cache.wait": lambda name, partial, limit: name in self.cache,
            "mochi.cache.copy": lambda name, filename: 632 if name in self.cache else None,
            "mochi.cache.delete": self.cache.discard,
            "mochi.file.clean": lambda name, room: name,
            "mochi.file.maximum": lambda: 1 << 30,
        }
        self.mochi = Mochi(handlers)
        self.scope = library(self.mochi)
        if cached:
            self.cache.add(self.scope["attachment_cache_name"]("a1"))

    def read(self, sql, *args):
        self.reads += 1
        answer = dict(self.row)
        if self.reads == self.adopted:
            # Another request's adoption finishes just after this read: it
            # flips the row, then drops the cached copy.
            self.row["entity"] = ""
            self.cache.clear()
        return answer


class TestAdopt(unittest.TestCase):

    def test_a_copy_dropped_after_the_row_is_read_is_not_fetched_again(self):
        # The second of two adopters wakes as the first's transfer ends, reads
        # the row still remote, and the first then flips it and drops the copy.
        store = Store(cached=True)
        store.adopted = 2
        self.assertTrue(store.scope["attachment_adopt"]("a1", "requester"))
        self.assertNotIn("mochi.stream", store.mochi.calls, "the original was fetched a second time")

    def test_a_copy_held_with_no_other_adopter_is_moved_into_storage(self):
        store = Store(cached=True)
        self.assertTrue(store.scope["attachment_adopt"]("a1", "requester"))
        self.assertNotIn("mochi.stream", store.mochi.calls)
        self.assertIn("mochi.db.execute", store.mochi.calls, "the row is flipped")

    def test_with_no_copy_the_original_is_fetched(self):
        store = Store(cached=False)
        store.scope["attachment_adopt"]("a1", "requester")
        self.assertIn("mochi.stream", store.mochi.calls)


if __name__ == "__main__":
    unittest.main()
