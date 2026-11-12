# Mochi shared Starlark library: Entity assets
# Copyright © 2026 Mochisoft OÜ
# SPDX-License-Identifier: Apache-2.0
#
# Relays an entity's asset - an image such as a person's avatar, or a data
# answer such as their style - from the service that owns it, keeping it in
# cache space for as long as the response tells the browser to: a page listing
# people would otherwise pay a P2P stream per face on every view. An image carries
# the validator its service builds from when it was set and its size, fresh or
# kept alike, so a client revalidating its copy gets a 304.
#
# The caller authorises first: asset_serve answers whatever it is asked for.
#
# Every definition is prefixed asset_; each app vendors this file as a symlink
# into apps/<app>/lib/, listed first in app.json "execute".

# How long a relayed asset is served from cache space, in seconds, and the
# max-age its response carries.
asset_lifetime = 300

# Per-slot byte caps matching what the people app accepts on upload; the routes
# relaying them may be public, so an uncapped stream could run indefinitely.
# The favicon takes the avatar's cap, since people answers a person with no
# favicon with their avatar. Unknown slots fall back to the largest cap.
asset_maximum = {"avatar": 2 * 1024 * 1024, "banner": 10 * 1024 * 1024, "favicon": 2 * 1024 * 1024}

# Assets the people service answers as data, never as bytes: bytes offered for
# one are not an answer the routes relaying it - which their pages read as JSON
# - can serve.
asset_data = ("information", "style")

# Image types a person slot may hold, mirroring the people app's own list. The
# content type is the remote host's claim, and the entity may be hosted on a
# server this operator does not control, so anything else is served as an
# opaque download. SVG is allowed: core sanitises it and serves it under a
# script-blocking CSP.
asset_types = (
    "image/png",
    "image/jpeg",
    "image/gif",
    "image/webp",
    "image/avif",
    "image/svg+xml",
    "image/x-icon",
    "image/vnd.microsoft.icon",
)

# asset_plain(value) -> bool: Whether a peer-supplied value survives a JSON
# round trip. json.encode raises on bytes, a non-string key or a non-finite
# float, and Starlark cannot catch it.
def asset_plain(value, depth=0):
    kind = type(value)
    if kind in ("string", "int", "bool", "NoneType"):
        return True
    if depth >= 16:
        return False
    if kind in ("list", "tuple"):
        for item in value:
            if not asset_plain(item, depth + 1):
                return False
        return True
    if kind == "dict":
        for key, item in value.items():
            if type(key) != "string" or not asset_plain(item, depth + 1):
                return False
        return True
    return False

# asset_name(service, entity, asset) -> string: The cache entry holding an
# asset's bytes. Beside it, under the same name with ".json" appended, is what
# the service answered: the data, the bytes' content type and size, or that the
# asset is not set.
def asset_name(service, entity, asset):
    return "assets/" + service + "/" + entity + "/" + asset

# asset_status(header) -> int: What the relay answers when the service did not
# answer 200: the service's own 4xx or 5xx when it names one, and 502 when it
# answered nothing usable - the stream closed, or a status that is not one. A
# 5xx tells a client holding a copy to keep showing it, as Android's image
# cache does, where a 4xx says the asset is gone or no longer the caller's. A
# 401 or 407 is the far end refusing this server, never the caller's own
# credentials, which it did not see: passed on, it would sign the caller out
# of the web client and Android alike, so it is the relay failing, a 502. The
# digits are tested one by one: isdigit admits any script's digits, which
# int() refuses with an error that aborts the action.
def asset_status(header):
    if type(header) != "dict":
        return 502
    status = header.get("status")
    if type(status) == "string" and len(status) == 3 and all([digit in "0123456789" for digit in status.elems()]):
        code = int(status)
        if code == 401 or code == 407:
            return 502
        if code >= 400 and code <= 599:
            return code
    return 502

# asset_tag(header) -> string or None: The validator for an answer's bytes, from
# when the service says the asset was set and its size, as people builds it for
# its own routes. It stays the same however often the entry is refilled, so a
# client's copy is revalidated against the bytes rather than against when this
# server last asked. A service from before the stamp sends none, and its bytes
# carry the cache entry's own validator.
def asset_tag(header):
    updated = header.get("updated")
    size = header.get("size")
    if type(updated) == "int" and updated > 0 and type(size) == "int" and size >= 0:
        return '"' + str(updated) + "-" + str(size) + '"'
    return None

# asset_entry(name, record) -> string: The cache entry holding the bytes a
# record describes. Bytes that carry the service's validator are kept under a
# name of their own, so a record names exactly the bytes it was written for: two
# relays straddling a change of image cannot leave one validator over the
# other's bytes, which a client would then revalidate to for as long as it
# stood. Bytes from a service that sends none are kept under the asset's name.
def asset_entry(name, record):
    tag = record.get("tag") if type(record) == "dict" else None
    if type(tag) == "string":
        return name + "-" + mochi.crypto.hash.sha256(tag)[:16]
    return name

# asset_send(a, entry, record, control) -> bool: Answer kept bytes, under the
# freshness given and the validator they were kept with. False when the entry
# has gone, with the headers taken back for whatever answers instead.
def asset_send(a, entry, record, control):
    a.header("Cache-Control", control)
    if type(record.get("tag")) == "string":
        a.header("ETag", record["tag"])
    if a.write.cache(entry, record["type"]):
        return True
    a.header("Cache-Control", "")
    a.header("ETag", "")
    return False

# asset_serve(a, entity, service, asset, lifetime, public, version, missing,
# unavailable) -> dict or None: Answer an entity's asset from the service that
# owns it: {"data": ...} for a data answer, otherwise the bytes are written to
# the response and None is returned. public marks the response cacheable by
# shared caches. version is a token the page sends to fetch a changed asset at
# once - the menu reloading the user's own avatar after they change it - and
# names its own entry, rather than meeting the one cached before the change.
# missing is the label a 4xx answers with, the asset's own "not set" unless the
# caller words it, as people does for a person it cannot find. A service that
# cannot be reached, or that fails, answers 502 or its own 5xx under
# unavailable, so a client keeps the copy it holds. The cache is kept in the
# caller's storage, which an anonymous caller has only on an entity's route.
def asset_serve(a, entity, service, asset, lifetime=asset_lifetime, public=False, version=None, missing="errors.asset_not_set", unavailable="errors.asset_unavailable"):
    # mochi.remote.stream aborts the action as a 500 on a malformed id, so
    # refuse one here as a 404 instead.
    if not entity or (not mochi.text.valid(entity, "entity") and not mochi.text.valid(entity, "fingerprint")):
        a.error.label(404, "errors.asset_unavailable", asset=asset, log=False)
        return None
    scope = "public" if public else "private"
    control = scope + ", max-age=" + str(lifetime)

    name = asset_name(service, entity, asset)
    if version:
        name = name + "." + mochi.crypto.hash.sha256(str(version))[:16]
    # An anonymous caller on an entity's route runs with the entity owner's
    # storage, and keeps its entries apart there: the owner's own were fetched
    # as the owner, and an anonymous caller is answered only what a fetch
    # naming nobody is. Anonymous on a class route has no storage at all. A
    # signed-in visitor to an entity a hosted domain publishes under a context
    # runs with the owner's storage too, and keeps entries of their own there,
    # fetched as themselves.
    if a.user == None:
        name = "anonymous/" + name
    elif a.entity != None and not a.owner and a.domain.route != None and a.domain.route.context:
        name = "viewer/" + a.user.id + "/" + name
    record = name + ".json"
    cached = (a.user != None or a.entity != None) and mochi.text.valid(record, "filepath")
    kept = None
    if cached:
        kept = json.decode(str(mochi.cache.read(record) or ""), None)
        if type(kept) != "dict":
            kept = None
        age = mochi.cache.age(record)
        if kept != None and age != None and age < lifetime:
            # What is left of the entry's lifetime, so a browser's copy expires
            # when the entry does, not a whole lifetime after it.
            remaining = scope + ", max-age=" + str(lifetime - age)
            if kept.get("missing") == True:
                a.error.label(404, missing, asset=asset, log=False)
                return None
            if "data" in kept:
                a.header("Cache-Control", remaining)
                return {"data": kept["data"]}
            # The size guards against bytes a concurrent relay replaced.
            entry = asset_entry(name, kept)
            if type(kept.get("type")) == "string" and mochi.cache.size(entry) == kept.get("size"):
                if asset_send(a, entry, kept, remaining):
                    return None

    # Asked at most twice: a second time only when kept bytes the service still
    # vouches for have gone by the time they are served.
    for attempt in (1, 2):
        s = mochi.remote.stream(entity, service, asset, {})
        if not s:
            a.error.label(502, unavailable, asset=asset, log=False)
            return None
        header = s.read()
        if type(header) != "dict" or header.get("status") != "200":
            # A 404 is the service saying the asset is not set - most people
            # have no avatar - so that is kept too; any other failure may pass,
            # and is asked about again.
            status = asset_status(header)
            if cached and status == 404:
                mochi.cache.write(record, json.encode({"missing": True}))
            a.error.label(status, missing if status < 500 else unavailable, asset=asset, log=False)
            return None
        if "data" in header:
            if cached and asset_plain(header["data"]):
                mochi.cache.write(record, json.encode({"data": header["data"]}))
            a.header("Cache-Control", control)
            return {"data": header["data"]}
        if asset in asset_data:
            s.close()
            a.error.label(502, unavailable, asset=asset, log=False)
            return None

        maximum = asset_maximum.get(asset, max(asset_maximum.values()))
        # A body declared past the cap is refused before anything is written,
        # rather than answered 200 and cut off part way.
        declared = header.get("size")
        if type(declared) == "int" and declared > maximum:
            s.close()
            a.error.label(502, unavailable, asset=asset, log=False)
            return None
        size = declared if type(declared) == "int" and declared >= 0 else -1
        content = header.get("content_type", "")
        if content not in asset_types:
            content = "application/octet-stream"
        tag = asset_tag(header)
        fresh = {"type": content}
        if tag:
            fresh["tag"] = tag
        entry = asset_entry(name, fresh)

        # The service still answers with the bytes kept: the stream is closed
        # unread, so a lapsed entry costs its owner a header rather than the
        # whole body again, and the kept bytes are served - the owner's handler
        # is not held while this server's client takes them. Kept bytes gone by
        # then - replaced by another relay, or let go by the cache - are asked
        # for again and relayed.
        if attempt == 1 and cached and tag and kept != None and kept.get("tag") == tag and kept.get("type") == content and size >= 0 and mochi.cache.size(entry) == size:
            s.close()
            if asset_send(a, entry, kept, control):
                mochi.cache.write(record, json.encode(kept))
                return None
            continue
        break

    # The body is relayed as it arrives and kept on the way through. core holds
    # it to the size the service declared: a body that ends short, or runs on
    # past it, aborts the response, so the client sees the transfer fail rather
    # than keep part of an image under its validator, and is not kept here.
    a.header("Cache-Control", control)
    a.header("Content-Type", content)
    if tag:
        a.header("ETag", tag)
    if not cached:
        a.write.stream(s, maximum=maximum, size=size)
        return None
    a.write.stream(s, maximum=maximum, cache=entry, size=size)
    # Kept whole, or kept for a revalidation answered 304: the record follows,
    # and the bytes of an image since replaced are let go.
    kept_size = mochi.cache.size(entry)
    if kept_size != None and (size < 0 or kept_size == size):
        fresh["size"] = kept_size
        if kept != None and "type" in kept and asset_entry(name, kept) != entry:
            mochi.cache.delete(asset_entry(name, kept))
        mochi.cache.write(record, json.encode(fresh))
    return None
