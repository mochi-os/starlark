# Mochi shared Starlark library: Entity assets
# Copyright © 2026 Mochisoft OÜ
# SPDX-License-Identifier: Apache-2.0
#
# Relays an entity's asset - an image such as a person's avatar, or a data
# answer such as their style - from the service that owns it, keeping it in
# cache space for as long as the response tells the browser to: a page listing
# people would otherwise pay a P2P stream per face on every view. An image served
# from cache space carries a validator, so a browser revalidating that copy while
# it is still kept gets a 304; a fresh relay carries none.
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

# asset_serve(a, entity, service, asset, lifetime, public, version) -> dict or
# None: Answer an entity's asset from the service that owns it: {"data": ...} for
# a data answer, otherwise the bytes are written to the response and None is
# returned. public marks the response cacheable by shared caches. version is a
# token the page sends to fetch a changed asset at once - the menu reloading
# the user's own avatar after they change it - and names its own entry, rather
# than meeting the one cached before the change. The cache is kept in the
# caller's storage, which an anonymous caller has only on an entity's route.
def asset_serve(a, entity, service, asset, lifetime=asset_lifetime, public=False, version=None):
    # mochi.remote.stream aborts the action as a 500 on a malformed id, so
    # refuse one here as a 404 instead.
    if not entity or (not mochi.text.valid(entity, "entity") and not mochi.text.valid(entity, "fingerprint")):
        a.error.label(404, "errors.asset_unavailable", asset=asset, log=False)
        return None
    control = ("public" if public else "private") + ", max-age=" + str(lifetime)

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
    if cached:
        age = mochi.cache.age(record)
        if age != None and age < lifetime:
            header = json.decode(str(mochi.cache.read(record) or ""), None)
            if type(header) == "dict" and header.get("missing") == True:
                a.error.label(404, "errors.asset_not_set", asset=asset, log=False)
                return None
            if type(header) == "dict" and "data" in header:
                a.header("Cache-Control", control)
                return {"data": header["data"]}
            # The size guards against bytes a concurrent relay replaced.
            if type(header) == "dict" and type(header.get("type")) == "string" and mochi.cache.size(name) == header.get("size"):
                a.header("Cache-Control", control)
                if a.write.cache(name, header["type"]):
                    return None

    s = mochi.remote.stream(entity, service, asset, {})
    if not s:
        a.error.label(404, "errors.asset_unavailable", asset=asset, log=False)
        return None
    header = s.read()
    if type(header) != "dict" or header.get("status") != "200":
        # A 404 is the service saying the asset is not set - most people have
        # no avatar - so that is kept too; any other failure may pass, and is
        # asked about again.
        if cached and type(header) == "dict" and header.get("status") == "404":
            mochi.cache.write(record, json.encode({"missing": True}))
        a.error.label(404, "errors.asset_not_set", asset=asset, log=False)
        return None
    a.header("Cache-Control", control)
    if "data" in header:
        if cached and asset_plain(header["data"]):
            mochi.cache.write(record, json.encode({"data": header["data"]}))
        return {"data": header["data"]}

    maximum = asset_maximum.get(asset, max(asset_maximum.values()))
    # A body declared past the cap is refused before anything is written, rather
    # than answered 200 and cut off part way.
    declared = header.get("size")
    if type(declared) == "int" and declared > maximum:
        a.error.label(404, "errors.asset_unavailable", asset=asset, log=False)
        return None
    content = header.get("content_type", "")
    if content not in asset_types:
        content = "application/octet-stream"
    a.header("Content-Type", content)
    if not cached:
        a.write.stream(s, maximum=maximum)
        return None
    a.write.stream(s, maximum=maximum, cache=name)
    # A relay cut short - the browser walking away, or the far end stopping
    # early - still fills the entry, so the size the service declared is what
    # shows the bytes are whole.
    size = mochi.cache.size(name)
    if size != None and (type(declared) != "int" or declared == size):
        mochi.cache.write(record, json.encode({"type": content, "size": size}))
    return None
