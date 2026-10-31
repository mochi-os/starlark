# Mochi shared Starlark library: Recommendations
# Copyright © 2026 Mochisoft OÜ
# SPDX-License-Identifier: Apache-2.0
#
# The recommendations service's list for a type and language, kept in cache
# space between asks: the list is the same for everyone reading a language, and
# asking the service over P2P costs half a second on every landing page. Each
# app filters out what the user already has and shapes the answer itself.
#
# Every definition is prefixed recommendation_; each app vendors this file as a
# symlink into apps/<app>/lib/, listed first in app.json "execute".

# The entity the recommendations service answers as.
recommendation_entity = "1JYmMpQU7fxvTrwHpNpiwKCgUg3odWqX7s9t1cLswSMAro5M2P"

# How long a fetched list is served before the service is asked again, in
# seconds.
recommendation_lifetime = 3600

# recommendation_text(value) -> string: A field of a recommendation as text; the
# service is remote, so anything else is dropped rather than handed on.
def recommendation_text(value):
    return value if type(value) == "string" else ""

# recommendation_name(kind, language) -> string: The cache entry holding the
# list for a kind and language.
def recommendation_name(kind, language):
    return "recommendations/" + kind + "-" + language

# recommendation_list(kind, language, lifetime) -> list or None: The service's
# recommendations of a kind ("feed", "wiki", ...) for a BCP 47 language, each
# {entity, name, blurb} as strings, not filtered for the user. None when the
# service could not be reached or did not answer with a list; a failure is not
# cached, so the next call asks again.
def recommendation_list(kind, language, lifetime=recommendation_lifetime):
    # Keyed on the language exactly as the service is asked for it, which may
    # be a preference such as "auto" rather than a BCP 47 tag.
    name = recommendation_name(kind, language)
    cached = mochi.text.valid(language, "constant") and mochi.text.valid(name, "filepath")
    if cached:
        age = mochi.cache.age(name)
        if age != None and age < lifetime:
            items = json.decode(str(mochi.cache.read(name) or ""), None)
            if type(items) == "list":
                return items

    s = mochi.remote.stream(recommendation_entity, "recommendations", "list", {"type": kind, "language": language})
    if not s:
        return None
    header = s.read()
    if type(header) != "dict" or header.get("status") != "200":
        s.close()
        return None
    body = s.read()
    s.close()
    # The service answered, with nothing usable: no recommendations, not a
    # failure, and not kept.
    if type(body) not in ("list", "tuple"):
        return []

    items = []
    for item in body:
        if type(item) != "dict":
            continue
        # A malformed id would raise in mochi.entity.fingerprint and abort the
        # caller, for as long as the list stays cached.
        entity = item.get("entity")
        if type(entity) != "string" or not mochi.text.valid(entity, "entity"):
            continue
        items.append({
            "entity": entity,
            "name": recommendation_text(item.get("name")),
            "blurb": recommendation_text(item.get("blurb")),
        })
    if cached:
        mochi.cache.write(name, json.encode(items))
    return items
