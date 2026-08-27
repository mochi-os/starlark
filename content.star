# Mochi shared Starlark library: Peer-supplied content
# Copyright © 2026 Mochisoft OÜ
# SPDX-License-Identifier: AGPL-3.0-only
# This file is part of Mochi, licensed under the GNU AGPL v3 with the Mochi
# Application Interface Exception - see license.txt and license-exception.md.
#
# Reading values a peer or client supplied without the handler dying on them.
# Starlark has no try/except, so a type error - ordering a peer's string against
# an int - ends the whole handler silently. Each function returns the value when
# it is the type the caller is about to use, and the fallback otherwise.
#
# Every definition is prefixed content_; each app vendors this file as a symlink
# into apps/<app>/lib/, listed first in app.json "execute".

# content_text(e, key, fallback) -> string: a text field from an event payload.
# Non-strings are dropped rather than coerced - str() would store a peer's list
# as "[1, 2, 3]" in somebody's page title.
def content_text(e, key, fallback=None):
	value = e.content(key)
	if type(value) == "string":
		return value
	return fallback

# content_number(e, key, fallback) -> int: a numeric field from an event
# payload. Floats and numeric strings are accepted: a JSON round trip (a
# broadcast replay) turns an int into a float, and the wire is not always CBOR.
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
# For a field inside a signed payload, where coercing "123" to 123 would change
# the bytes the peer signed and fail the verification.
def content_is_number(value):
	return type(value) in ["int", "float"]

# content_decode(raw, fallback) -> value: json.decode that cannot abort. An
# explicit default is what makes json.decode total; this also catches a decode
# that yields the wrong shape rather than leaving it to the next line.
def content_decode(raw, fallback=None):
	if type(raw) != "string" or raw == "":
		return fallback
	value = json.decode(raw, fallback)
	if value == None:
		return fallback
	return value

# content_list(value, maximum) -> list: a list field, bounded. Over the cap the
# whole field is refused rather than truncated - half a batch is a different
# batch, and applying part of one is how a replica diverges.
#
# No app calls this yet; it is kept as the shared shape for the sequence-typed
# payload guard each app currently writes inline.
def content_list(value, maximum):
	if type(value) != "list":
		return []
	if len(value) > maximum:
		return []
	return value
