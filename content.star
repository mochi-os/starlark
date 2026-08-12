# Mochi shared Starlark library: Peer-supplied content
# Copyright © 2026 Mochisoft OÜ
# SPDX-License-Identifier: AGPL-3.0-only
# This file is part of Mochi, licensed under the GNU AGPL v3 with the
# Mochi Application Interface Exception - see license.txt and license-exception.md.
#
# Reading values a peer or client supplied, without the handler dying on them.
# Each consuming app vendors this file (a symlink into apps/<app>/lib/, listed
# first in app.json "execute").
#
# The problem this exists for: Starlark has no try/except, so ANY operation the
# runtime refuses ends the whole handler on the spot. A payload field carries no
# type guarantee - a peer sends what it likes - so `e.content("updated") > now`
# is not a comparison, it is a coin toss between comparing and killing the
# handler, because Starlark refuses to order a string against an int. The page
# never lands, the tag never applies, the replica quietly diverges, and nothing
# is logged, because the abort is not an error path anyone wrote.
#
# Each function answers the same way: return the value when it IS the type the
# caller is about to use, and the fallback otherwise. That turns a fatal type
# error into an ordinary `if not x: return`, which every handler already has.
#
# Naming: every definition is prefixed content_. The library runs before the
# app's own files (execute order is resolve order), so it references no app
# global.

content_library_version = "1.0"

# content_text(e, key, fallback) -> string: a text field from an event payload.
#
# Anything that is not a string is dropped rather than coerced: str() would turn
# a peer's list into "[1, 2, 3]" and store that as somebody's page title, which
# is worse than treating the field as absent.
def content_text(e, key, fallback=None):
	value = e.content(key)
	if type(value) == "string":
		return value
	return fallback

# content_number(e, key, fallback) -> int: a numeric field from an event payload.
#
# Floats are accepted and truncated because a value that has been through a JSON
# round trip comes back as a float - a broadcast replay does exactly that, so
# refusing floats would reject the app's own re-sent events. A numeric string is
# accepted for the same reason: the wire is not always CBOR.
def content_number(e, key, fallback=0):
	value = e.content(key)
	kind = type(value)
	if kind == "int":
		return value
	if kind == "float":
		return int(value)
	if kind == "string" and mochi.text.valid(value, "integer"):
		return int(value)
	return fallback

# content_is_number(value) -> bool: is this value safe to compare numerically?
#
# For a field that is ALSO part of a signed payload, where content_number would
# be wrong: coercing "123" to 123 changes the bytes the peer signed, so the
# signature then fails to verify and a legitimate event is refused. Such a
# field has to be checked and passed through untouched, never rewritten.
def content_is_number(value):
	return type(value) in ["int", "float"]

# content_decode(raw, fallback) -> value: json.decode that cannot abort.
#
# json.decode raises on malformed input, and the caller is usually holding a
# string that came from a request or a peer. Passing an explicit default is the
# documented way to make it total (see the api-utilities wiki page); this exists
# so no call site has to remember, and so a decode that yields the wrong SHAPE
# is caught here rather than three lines later.
def content_decode(raw, fallback=None):
	if type(raw) != "string" or raw == "":
		return fallback
	value = json.decode(raw, fallback)
	if value == None:
		return fallback
	return value

# content_list(value, maximum) -> list: a list field, bounded.
#
# A peer chooses the length as freely as the contents, and every element costs
# memory and a loop iteration on the receiver. Over the cap the whole field is
# refused rather than truncated: half a batch is not a smaller batch, it is a
# different one, and silently applying part of it is how a replica diverges.
def content_list(value, maximum):
	if type(value) != "list":
		return []
	if len(value) > maximum:
		return []
	return value
