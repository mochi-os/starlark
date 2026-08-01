# Mochi shared Starlark library: Attachments
# Copyright © 2026 Mochisoft OÜ
# SPDX-License-Identifier: AGPL-3.0-only
# This file is part of Mochi, licensed under the GNU AGPL v3 with the
# Mochi Application Interface Exception - see license.txt and license-exception.md.
#
# App-owned file attachments. Each consuming app vendors this file (a symlink
# into apps/<app>/lib/, listed first in app.json "execute") and owns its
# attachments table in its own database. Core keeps only the primitives this
# builds on: mochi.file.* for blob storage, mochi.image.variant for image
# variants, mochi.cache.* for re-obtainable copies, a.upload / a.files for
# multipart intake, a.write.cache / e.write.cache for serving.
#
# Naming: every definition is prefixed attachment_. The library runs before the
# app's own files (execute order is resolve order), so it references no app
# global; app-specific judgement arrives as a callback argument.
#
# Storage. An attachment's original bytes live in the app's file storage at the
# filename "<id>_<name>" - identical to the layout core used, so a migration
# adopts existing files in place. The metadata row lives in the app's own
# `attachments` table. Image variants (thumbnail, preview) are re-computable and
# live in cache space; remote copies pulled from a peer live in cache too. Both
# may be evicted and are regenerated or re-pulled on the next request.

attachment_library_version = "1.0"

# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------

# attachment_schema_create() creates the attachments table and its object index
# in the app's own database. Call from database_create, and from the
# database_upgrade step that introduces attachments. Idempotent.
def attachment_schema_create():
    mochi.db.execute("""create table if not exists attachments (
        id text not null primary key,
        object text not null,
        entity text not null default '',
        name text not null,
        size integer not null,
        content_type text not null default '',
        creator text not null default '',
        caption text not null default '',
        description text not null default '',
        rank integer not null default 0,
        created integer not null
    )""")
    mochi.db.execute("create index if not exists attachments_object on attachments( object )")

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# The storage filename for an attachment. Matches core's attachment_filename so
# migrated files are found in place. filepath.Base defence against separators is
# applied by stripping path components.
def attachment_filename(id, name):
    safe = name
    for sep in ["/", "\\"]:
        if sep in safe:
            safe = safe.split(sep)[-1]
    if safe == "" or safe == "." or safe == "..":
        safe = "file"
    return id + "_" + safe

def attachment_is_image(name):
    lower = name.lower()
    for ext in [".gif", ".jpeg", ".jpg", ".png", ".webp"]:
        if lower.endswith(ext):
            return True
    return False

def attachment_content_type(name):
    lower = name.lower()
    types = {
        ".gif": "image/gif", ".jpeg": "image/jpeg", ".jpg": "image/jpeg",
        ".png": "image/png", ".webp": "image/webp", ".pdf": "application/pdf",
        ".txt": "text/plain", ".svg": "image/svg+xml",
    }
    for ext in types:
        if lower.endswith(ext):
            return types[ext]
    return "application/octet-stream"

def attachment_next_rank(object):
    row = mochi.db.row("select max(rank) as high from attachments where object=?", object)
    if row and row.get("high") != None:
        return int(row["high"]) + 1
    return 1

# attachment_url reproduces the URL shapes core built, so the response shape
# apps' web and Android clients consume is unchanged. With an entity: the public
# entity-scoped route /<app>/<entity>/-/attachments/<id>. Without: the
# class-level /<app>/attachments/<id>.
def attachment_url(prefix, entity, id):
    if entity:
        return "/" + prefix + "/" + entity + "/-/attachments/" + id
    return "/" + prefix + "/attachments/" + id

# attachment_map converts a database row to the response dict, byte-for-byte
# compatible with core's Attachment.to_map: the same keys, and url /
# thumbnail_url / preview_url only when a prefix is supplied.
def attachment_map(row, prefix, entity):
    image = attachment_is_image(row["name"])
    result = {
        "id": row["id"],
        "object": row["object"],
        "entity": row.get("entity", ""),
        "name": row["name"],
        "size": row["size"],
        "content_type": row.get("content_type", ""),
        "type": row.get("content_type", ""),
        "creator": row.get("creator", ""),
        "caption": row.get("caption", ""),
        "description": row.get("description", ""),
        "rank": row.get("rank", 0),
        "created": row["created"],
        "image": image,
    }
    if prefix:
        url = attachment_url(prefix, entity, row["id"])
        result["url"] = url
        if image:
            result["thumbnail_url"] = url + "/thumbnail"
            result["preview_url"] = url + "/preview"
    return result

def attachment_row(id):
    return mochi.db.row("select * from attachments where id=?", id)

# attachment_conflict reports whether id already exists bound to a different
# object. The receive paths write ids chosen by a peer; an id already held under
# another object must not be repointed (that would detach an attachment from the
# message it belongs to). Re-storing under the same object is an ordinary update
# of the descriptive fields; attachment_store keeps provenance out of it.
def attachment_conflict(id, object):
    row = mochi.db.row("select object from attachments where id=?", id)
    if not row:
        return False
    return row["object"] != object

# attachment_row_write writes a metadata row. entity is provenance: "" for our own
# (bytes local), an entity id for a remote copy (bytes pulled on demand).
def attachment_row_write(id, object, name, size, content_type, creator, caption, description, rank, created, entity):
    mochi.db.execute(
        "insert into attachments ( id, object, entity, name, size, content_type, creator, caption, description, rank, created ) values ( ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ? )",
        id, object, entity, name, size, content_type, creator, caption, description, rank, created)

# ---------------------------------------------------------------------------
# Local operations (app's own uploads and reads)
# ---------------------------------------------------------------------------

# attachment_save(a, object, field="files", captions=[], descriptions=[]) reads
# a multipart file field and stores every file as an attachment on object.
# Returns the list of response dicts. Bytes stream to disk one file at a time
# (a.upload by index), so no upload is held whole in memory.
def attachment_save(a, object, field="files", captions=[], descriptions=[]):
    prefix = mochi.app.url()
    creator = ""
    if a.user and a.user.identity:
        creator = a.user.identity.id

    results = []
    files = a.files(field)
    for i in range(len(files)):
        meta = files[i]
        name = meta["name"]
        id = mochi.uid()
        filename = attachment_filename(id, name)
        # Bounded against core's own figure rather than a copy of it. An
        # attachment above what a transfer carries is kept whole by its owner
        # and received as a prefix by every subscriber, silently.
        size = a.upload(field, filename, index=i, maximum=mochi.file.maximum())
        content_type = meta.get("content_type", "")
        if not content_type:
            content_type = attachment_content_type(name)
        caption = captions[i] if i < len(captions) else ""
        description = descriptions[i] if i < len(descriptions) else ""
        rank = attachment_next_rank(object)
        created = mochi.time.now()
        # File before row: a builtin error here aborts the handler with no
        # cleanup, so the benign failure is an orphan file (swept later), never
        # a row pointing at nothing.
        attachment_row_write(id, object, name, size, content_type, creator, caption, description, rank, created, "")
        results.append(attachment_map({
            "id": id, "object": object, "entity": "", "name": name, "size": size,
            "content_type": content_type, "creator": creator, "caption": caption,
            "description": description, "rank": rank, "created": created,
        }, prefix, ""))
    if results:
        attachment_sweep()
    return results

# attachment_create(object, name, data, content_type="", caption="",
# description="", id="", entity="") stores an attachment from bytes already in
# hand (a copy, a decoded payload). Pass id to preserve an existing identifier
# (federation), entity for a remote-provenance row.
def attachment_create(object, name, data, content_type="", caption="", description="", id="", entity=""):
    # Same ceiling as the upload path: bytes already in hand are no different
    # from bytes arriving over HTTP once they are an attachment.
    if not entity and len(data) > mochi.file.maximum():
        mochi.log.debug("attachment_create refusing %s: %d bytes exceeds the object limit", name, len(data))
        return None
    if not id:
        id = mochi.uid()
    if not content_type:
        content_type = attachment_content_type(name)
    if not entity:
        mochi.file.write(attachment_filename(id, name), data)
    rank = attachment_next_rank(object)
    created = mochi.time.now()
    attachment_row_write(id, object, name, len(data), content_type, "", caption, description, rank, created, entity)
    return attachment_map(attachment_row(id), mochi.app.url(), "")

# attachment_receive(object, name, stream, content_type="", id="") stores an
# attachment whose bytes arrive on an open stream (a source pulling an upload
# from a replica). Streams straight to file storage - no whole-file buffering -
# and records an own row (entity ""). Returns the response dict, or None if the
# stream carried nothing. Pass id to preserve a federated identifier.
def attachment_receive(object, name, stream, content_type="", id=""):
    if not id:
        id = mochi.uid()
    if not content_type:
        content_type = attachment_content_type(name)
    filename = attachment_filename(id, name)
    size = stream.read.file(filename)
    if not size:
        mochi.file.delete(filename)
        return None
    rank = attachment_next_rank(object)
    attachment_row_write(id, object, name, size, content_type, "", "", "", rank, mochi.time.now(), "")
    return attachment_map(attachment_row(id), mochi.app.url(), "")

# attachment_insert(object, name, data, position, content_type="", caption="",
# description="") stores an attachment from bytes at a specific 1-based rank,
# shifting later attachments down. Returns the response dict.
def attachment_insert(object, name, data, position, content_type="", caption="", description=""):
    if len(data) > mochi.file.maximum():
        mochi.log.debug("attachment_insert refusing %s: %d bytes exceeds the object limit", name, len(data))
        return None
    id = mochi.uid()
    if not content_type:
        content_type = attachment_content_type(name)
    mochi.file.write(attachment_filename(id, name), data)
    mochi.db.execute("update attachments set rank = rank + 1 where object=? and rank >= ?", object, position)
    created = mochi.time.now()
    attachment_row_write(id, object, name, len(data), content_type, "", caption, description, position, created, "")
    return attachment_map(attachment_row(id), mochi.app.url(), "")

# attachment_list(object, entity="") returns object's attachments ordered by
# rank, as response dicts. Pass the route entity to get public entity-scoped
# URLs. The entity argument is URL data, not an access filter (rows may
# legitimately carry different entities); authorization is the caller's.
def attachment_list(object, entity=""):
    prefix = mochi.app.url()
    rows = mochi.db.rows("select * from attachments where object=? order by rank", object)
    return [attachment_map(row, prefix, entity) for row in rows]

def attachment_get(id, entity=""):
    row = attachment_row(id)
    if not row:
        return None
    return attachment_map(row, mochi.app.url(), entity)

def attachment_exists(id):
    return mochi.db.exists("select 1 from attachments where id=?", id)

# attachment_delete(id) removes an attachment: row first, then file, so the
# benign failure leaves an orphan file rather than a live row with no bytes.
# Shifts the remaining ranks down. Returns True if a row was removed.
def attachment_delete(id):
    row = attachment_row(id)
    if not row:
        return False
    mochi.db.execute("delete from attachments where id=?", id)
    mochi.db.execute("update attachments set rank = rank - 1 where object=? and rank > ?", row["object"], row["rank"])
    if not row.get("entity"):
        mochi.file.delete(attachment_filename(id, row["name"]))
    attachment_forget(row)
    return True

def attachment_clear(object):
    rows = mochi.db.rows("select * from attachments where object=?", object)
    mochi.db.execute("delete from attachments where object=?", object)
    for row in rows:
        if not row.get("entity"):
            mochi.file.delete(attachment_filename(row["id"], row["name"]))
        attachment_forget(row)

def attachment_move(id, position):
    row = attachment_row(id)
    if not row:
        return None
    old = row["rank"]
    new = position
    if old != new:
        if new < old:
            mochi.db.execute("update attachments set rank = rank + 1 where object=? and rank >= ? and rank < ?", row["object"], new, old)
        else:
            mochi.db.execute("update attachments set rank = rank - 1 where object=? and rank > ? and rank <= ?", row["object"], old, new)
        mochi.db.execute("update attachments set rank=? where id=?", new, id)
    return attachment_map(attachment_row(id), mochi.app.url(), "")

def attachment_update(id, caption, description):
    if not attachment_exists(id):
        return None
    mochi.db.execute("update attachments set caption=?, description=? where id=?", caption, description, id)
    return attachment_map(attachment_row(id), mochi.app.url(), "")

# attachment_copy(id, object, frm="", caption="", description="") duplicates an
# attachment onto another object and returns the new response dict, or None if
# the bytes cannot be obtained. The bytes stream from one file to the other and
# are never held in memory, which is what separates this from reading with
# attachment_data and writing back with attachment_create: an attachment may be
# as large as the uploader's remaining quota, and the Starlark interpreter
# shares its process with every other user on the host.
#
# The copy is always ours (entity ""), because a forwarded or duplicated
# attachment is no longer a reference to the peer's: for a remote source the
# bytes are pulled into cache first and then kept.
def attachment_copy(id, object, frm="", caption="", description=""):
    row = attachment_row(id)
    if not row:
        return None

    new = mochi.uid()
    name = row["name"]
    destination = attachment_filename(new, name)

    if row.get("entity"):
        if not attachment_pull(id, row, frm):
            return None
        size = mochi.cache.copy(attachment_cache_name(id), destination)
    else:
        size = mochi.file.copy(attachment_filename(id, name), destination)
    if size == None:
        return None

    attachment_row_write(new, object, name, size, row.get("content_type", ""), "",
                         caption, description, attachment_next_rank(object), mochi.time.now(), "")
    return attachment_map(attachment_row(new), mochi.app.url(), "")

# attachment_fetch(id, frm="") makes sure a remote attachment's bytes are in
# cache, returning whether they are available. For a row we hold locally there
# is nothing to do. Callers that only want to warm the cache use this rather
# than attachment_data, whose return value they would discard - and which would
# read the whole object into memory to produce it.
def attachment_fetch(id, frm=""):
    row = attachment_row(id)
    if not row:
        return False
    if not row.get("entity"):
        return True
    return attachment_pull(id, row, frm)

# attachment_entry(id, name, frm="") returns a mochi.archive.write entry naming
# this attachment's bytes, or None if they cannot be obtained. Pair it with
# attachment_extract on the way back in. This is how an export carries
# attachments: the archive streams each one straight off disk, where embedding
# them in the export's own JSON meant holding every one of them, base64-expanded
# by a third, in memory at the same time.
#
# A remote copy is pulled into cache first and referenced there, so exporting a
# subscribed container's attachments does not first turn them into ours.
def attachment_entry(id, name, frm=""):
    row = attachment_row(id)
    if not row:
        return None
    if row.get("entity"):
        if not attachment_pull(id, row, frm):
            return None
        return {"name": name, "cache": attachment_cache_name(id)}
    return {"name": name, "file": attachment_filename(id, row["name"])}

# attachment_extract(archive, entry, object, name, ...) stores one entry of an
# archive as an attachment on object and returns the response dict, or None if
# the entry is absent. The bytes go from the container to their resting place
# without being read, which is the half of an import that used to decode a
# base64 string per attachment and hold the result.
def attachment_extract(archive, entry, object, name, content_type="", caption="", description=""):
    id = mochi.uid()
    size = mochi.archive.extract(archive, entry, attachment_filename(id, name))
    if size == None:
        return None
    if not content_type:
        content_type = attachment_content_type(name)
    attachment_row_write(id, object, name, size, content_type, "", caption, description,
                         attachment_next_rank(object), mochi.time.now(), "")
    return attachment_map(attachment_row(id), mochi.app.url(), "")

# attachment_data(id, frm="") returns an attachment's bytes, or None. For an own
# row it reads local storage; for a remote row it pulls from the source on
# demand (as the old mochi.attachment.data did) and returns the cached copy.
# frm is the requesting user's identity, needed to open the pull stream - pass
# it (a.user.identity.id) when the row may be remote (copy, export). Used by
# paths that need the bytes in hand.
def attachment_data(id, frm=""):
    row = attachment_row(id)
    if not row:
        return None
    # An attachment may be as large as the uploader's whole quota, and this is
    # the one path that materialises it as a Starlark value - in a process every
    # user on the host shares. Callers moving bytes rather than inspecting them
    # want attachment_copy or attachment_entry, which stream.
    if int(row.get("size", 0)) > attachment_memory_maximum:
        mochi.log.debug("attachment_data refusing %s: %d bytes exceeds the in-memory limit", id, row.get("size", 0))
        return None
    if row.get("entity"):
        if not attachment_pull(id, row, frm):
            return None
        return mochi.cache.read(attachment_cache_name(id))
    return mochi.file.read(attachment_filename(id, row["name"]))

# ---------------------------------------------------------------------------
# Variants and cache naming
# ---------------------------------------------------------------------------

# The cache entry name for a remote copy: the original when variant is empty, or
# a per-variant entry (thumbnail, preview). Ids are unique, so entries never
# collide across attachments.
def attachment_cache_name(id, variant=""):
    if variant:
        return "remote/" + id + "_" + variant
    return "remote/" + id

# attachment_forget drops an attachment's cache entries. Image variants of an
# OWN attachment are left to expire by eviction: mochi.image.variant owns their
# naming, ids are never reused, so a stale variant is harmless and regenerates.
# A remote copy's entries share the id, so they are dropped explicitly.
def attachment_forget(row):
    if row.get("entity"):
        mochi.cache.delete(attachment_cache_name(row["id"], ""))
        mochi.cache.delete(attachment_cache_name(row["id"], "thumbnail"))
        mochi.cache.delete(attachment_cache_name(row["id"], "preview"))

# ---------------------------------------------------------------------------
# HTTP serving (the action is the gate)
# ---------------------------------------------------------------------------

# attachment_serve(a, id, container, authorize, variant="", member=None) serves
# an attachment's bytes (or an image variant) to the HTTP response. The caller
# MUST have resolved container and pass authorize(container) -> bool; the library
# applies no access check of its own. The attachment is bound to container -
# directly, or through member(object) -> bool for attachments on the container's
# children (a wiki's comments) - so one container's route cannot fetch another's
# attachment by id. Writes an error label on refusal or absence.
def attachment_serve(a, id, container, authorize, variant="", member=None):
    if not authorize(container):
        a.error.label(403, "attachment.errors.denied")
        return
    row = attachment_row(id)
    if not row:
        a.error.label(404, "attachment.errors.not_found")
        return
    if not attachment_bound(row, container, member):
        a.error.label(404, "attachment.errors.not_found")
        return

    # Remote row: pull the requested representation (original, or an image
    # variant the source renders) into cache on demand, then serve it. A
    # variant that cannot be produced falls back to the original. The stream's
    # "from" is the requesting user's identity when authenticated (which the
    # source authorizes), else the container's route entity for a public pull.
    if row.get("entity"):
        frm = a.user.identity.id if (a.user and a.user.identity) else container
        want = variant if (variant and attachment_is_image(row["name"])) else ""
        if want and attachment_pull(id, row, frm, want):
            a.write.cache(attachment_cache_name(id, want), content_type=row.get("content_type", ""))
            return
        if attachment_pull(id, row, frm, ""):
            a.write.cache(attachment_cache_name(id, ""), content_type=row.get("content_type", ""))
            return
        a.error.label(404, "attachment.errors.not_found")
        return

    # Own row: serve the original from file storage, or an image variant which
    # mochi.image.variant renders into cache on demand.
    if variant and attachment_is_image(row["name"]):
        name = mochi.image.variant(attachment_filename(id, row["name"]), variant)
        if name and a.write.cache(name, content_type=row.get("content_type", "")):
            return
    a.write.file(attachment_filename(id, row["name"]))

# attachment_bound reports whether an attachment belongs to container, either
# directly (object == container) or via the caller's member() predicate (a
# comment of the container, etc.). member defaults to no extra membership.
def attachment_bound(row, container, member=None):
    if row["object"] == container:
        return True
    if member:
        return member(row["object"])
    return False

# ---------------------------------------------------------------------------
# Receive side (store metadata from the app's own event handlers)
# ---------------------------------------------------------------------------

# attachment_store(rows, entity, object=None) records remote attachment metadata
# from within the app's own event handler. sender authorization is the handler's
# responsibility (the domain event it rides carries the sender it already
# validated); this only writes rows. entity is the provenance of the bytes.
# Skips a row whose id already belongs to a different object. Returns the count
# stored.
def attachment_store(rows, entity, object=None):
    count = 0
    for att in rows:
        if type(att) != "dict":
            continue
        id = att.get("id")
        if not attachment_identifier(id):
            continue
        target = object if object != None else att.get("object", "")
        if type(target) != "string" or not target:
            continue
        if attachment_conflict(id, target):
            continue

        name = attachment_text(att.get("name", ""), attachment_name_maximum)
        size = attachment_number(att.get("size", 0))
        content_type = attachment_text(att.get("content_type", ""), attachment_name_maximum)
        caption = attachment_text(att.get("caption", ""), attachment_text_maximum)
        description = attachment_text(att.get("description", ""), attachment_text_maximum)
        rank = attachment_number(att.get("rank", 0))

        # An id we already hold under this object is a metadata update, and the
        # sender does not get to restate where the bytes come from. entity is
        # what decides that - "" reads our own file, an entity id pulls from that
        # peer - so overwriting it turns a file we stored into one fetched from
        # whoever sent the update, under its original name. creator and created
        # are the same kind of claim about the past. Only the descriptive fields
        # move.
        existing = attachment_row(id)
        if existing:
            mochi.db.execute(
                "update attachments set name=?, size=?, content_type=?, caption=?, description=?, rank=? where id=?",
                name, size, content_type, caption, description, rank, id)
            count = count + 1
            continue

        mochi.db.execute(
            "insert into attachments ( id, object, entity, name, size, content_type, creator, caption, description, rank, created ) values ( ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ? )",
            id, target, entity, name, size, content_type,
            attachment_text(att.get("creator", ""), attachment_name_maximum),
            caption, description, rank,
            attachment_number(att.get("created", 0)) or mochi.time.now())
        count = count + 1
    return count

# A peer's row is data, not a promise about its own shape. The three helpers
# below reduce each field to the type the rest of the library assumes, because
# the caller's authorisation answers whether this peer may send us anything at
# all - not whether what arrived is well formed. A field of the wrong type is
# not inert: a name that is a number reaches name.lower() in
# attachment_is_image and aborts the handler, which Starlark gives no way to
# recover from.

attachment_name_maximum = 255
attachment_text_maximum = 1000

# attachment_identifier reports whether id is a well formed attachment id: 32
# characters of lowercase alphanumeric, matching what core accepts. A malformed
# one cannot address anything - it becomes a cache name core's own path check
# refuses - so the row would never resolve and is dropped instead.
def attachment_identifier(id):
    if type(id) != "string" or len(id) != 32:
        return False
    for i in range(len(id)):
        if id[i] not in "0123456789abcdefghijklmnopqrstuvwxyz":
            return False
    return True

# attachment_text reduces a field to a string of at most maximum characters.
# Anything that is not a string reads as absent rather than rejecting the row,
# so one malformed field costs a caption and not the attachment.
def attachment_text(value, maximum):
    if type(value) != "string":
        return ""
    if len(value) > maximum:
        return value[:maximum]
    return value

# attachment_number reduces a field to a non-negative integer. Floats are
# expected rather than exceptional: a number crossing the network as JSON
# arrives as one.
def attachment_number(value):
    kind = type(value)
    if kind == "int":
        return value if value > 0 else 0
    if kind == "float":
        rounded = int(value)
        return rounded if rounded > 0 else 0
    return 0

# ---------------------------------------------------------------------------
# Byte transfer (requester and responder)
# ---------------------------------------------------------------------------

# attachment_backoff_seconds is how long a failed pull suppresses retries. Not a
# tombstone: after it elapses the next access tries again, so a peer that comes
# back (or a lagging host that upgrades) heals without intervention.
attachment_backoff_seconds = 300

# The largest attachment attachment_data will build as a Starlark value. Not a
# storage limit - it bounds one function that has to hold what it returns.
attachment_memory_maximum = 64 * 1024 * 1024

def attachment_backoff_name(id, variant=""):
    if variant:
        return "backoff/" + id + "_" + variant
    return "backoff/" + id

# attachment_pull(id, row, variant="") ensures a remote attachment's bytes (the
# original, or an image variant the source renders) are in the cache, requesting
# them from the container's source when absent. Returns True if present
# afterwards. Applies time-based backoff on failure. The source is the row's
# provenance entity (app state), never a field a response claims.
def attachment_pull(id, row, frm, variant=""):
    name = attachment_cache_name(id, variant)
    if mochi.cache.path(name):
        return True
    age = mochi.cache.age(attachment_backoff_name(id, variant))
    if age != None and age < attachment_backoff_seconds:
        return False  # still within the backoff window; not a tombstone

    entity = row.get("entity", "")
    if not entity or not frm:
        return False
    # `frm` is the local entity opening the stream - the requesting user's
    # identity (which the responder authorizes) for an authenticated pull, or
    # the container's route entity for an anonymous public one. `to` is the
    # source from app state (the row's provenance), never a field a response
    # claims.
    stream = mochi.stream(
        {"from": frm, "to": entity, "service": mochi.app.url(), "event": "attachment/fetch"},
        {"id": id, "object": row["object"], "variant": variant})
    ok = False
    if stream:
        response = stream.read()
        if response and response.get("status") == "200":
            written = mochi.cache.write(name, stream)
            if attachment_complete(written, int(row.get("size", 0)), variant):
                ok = True
            else:
                mochi.cache.delete(name)
    if not ok:
        # Record the failure time; attachment_backoff_seconds later the next
        # access retries. cache.age reads the write time without touching it.
        mochi.cache.write(attachment_backoff_name(id, variant), "1")
    return ok

# attachment_complete judges a pulled body against the size the row declares.
# Originals only: a variant is rendered by the source and its size is not known
# ahead of time, so there is nothing to compare against.
#
# Both directions matter, and only one used to be checked. A response that
# grossly overshoots is a peer filling our cache with garbage. One that falls
# short is a truncated transfer - a dropped connection, a responder that died
# mid-file, or a transfer limit below the size of the stored object - and
# accepting it caches a prefix, serves it as if whole, and never retries,
# because the next pull finds the entry present. That failure is silent at both
# ends and leaves the bytes disagreeing with the metadata.
def attachment_complete(written, declared, variant=""):
    if variant or declared <= 0:
        return True
    if written > declared * 2:
        return False
    return written >= declared

# attachment_respond(e, container, authorize, member=None) answers a byte-pull
# request (an app event) with an attachment's bytes. Fixed sequence: resolve the
# requester from the signed header, authorize it against container, bind the
# requested id to container, then stream. Never trusts a reply-to in the body.
def attachment_respond(e, container, authorize, member=None):
    sender = e.header("from")
    if not sender:
        e.write({"status": "401"})
        return
    if not container:
        e.write({"status": "404"})
        return
    if not authorize(sender, container):
        e.write({"status": "403"})
        return
    id = e.content("id")
    if not id:
        e.write({"status": "400"})
        return
    row = attachment_row(id)
    if not row or not attachment_bound(row, container, member):
        e.write({"status": "404"})
        return
    if row.get("entity"):
        # We hold metadata but not the bytes (we are not the source); do not
        # relay another peer's copy.
        e.write({"status": "404"})
        return

    # A requester may ask for an image variant; render it from our own original
    # so the subscriber pulls the small copy rather than the full image. A
    # variant that cannot be produced falls back to the original.
    variant = e.content("variant", "")
    if variant and attachment_is_image(row["name"]):
        name = mochi.image.variant(attachment_filename(id, row["name"]), variant)
        if name:
            e.write({"status": "200"})
            e.write.cache(name)
            return
    e.write({"status": "200"})
    e.write.file(attachment_filename(id, row["name"]))

# ---------------------------------------------------------------------------
# Orphan sweep
# ---------------------------------------------------------------------------

# attachment_sweep removes stored files that no row references. A create writes
# the file before the row, so a mid-operation abort leaves an orphan file; this
# collects them. Run opportunistically from attachment_save. Bounded work: it
# only inspects files whose name matches the "<id>_" attachment pattern.
#
# age is how long a file must have gone untouched to count as abandoned. A file
# with no row is not necessarily an orphan: another request may be part-way
# through writing one, and until its row lands the two are indistinguishable by
# name. Sweeping immediately would delete bytes an upload still in flight is
# about to claim, leaving a row whose file is gone. A handler cannot outlive the
# Starlark time limit, so anything untouched for an hour has no writer left.
#
# Skipped entirely where mochi.file.age is unavailable, which is how this reads
# on a server older than the API: leaving orphans costs disk, deleting a live
# upload costs the file.
def attachment_sweep(age=3600):
    if not hasattr(mochi.file, "age"):
        return
    files = mochi.file.list("")
    if not files:
        return
    for entry in files:
        fname = entry.get("name", "") if type(entry) == "dict" else entry
        under = fname.find("_")
        if under <= 0:
            continue
        id = fname[:under]
        # An attachment id is a 32-character hex uid (mochi.uid with the UUID
        # hyphens removed); anything else is some other app file, left alone.
        if len(id) != 32 or not attachment_hex(id):
            continue
        if attachment_exists(id):
            continue
        settled = mochi.file.age(fname)
        if settled == None or settled < age:
            continue
        mochi.file.delete(fname)

# attachment_hex reports whether every character is a lowercase hex digit, so
# the orphan sweep only touches uid-shaped names.
def attachment_hex(s):
    for i in range(len(s)):
        if s[i] not in "0123456789abcdef":
            return False
    return True

# ---------------------------------------------------------------------------
# Migration (transition bridge)
# ---------------------------------------------------------------------------

# attachment_migrate() copies attachment rows out of core's managed store into
# this app's own table, once, from a database_upgrade step. Ids are preserved
# verbatim (URLs and remote references depend on them). Own rows (entity "")
# keep their files in place; remote rows keep pull-on-demand. If the bridge is
# gone (a dormant user migrating after the cleanup release), it aborts without
# advancing the version so the step retries when an export appears.
def attachment_migrate():
    rows = mochi.attachment.export()
    if rows == None:
        mochi.db.abort("attachment bridge unavailable")
        return
    for att in rows:
        id = att.get("id")
        if not id or attachment_exists(id):
            continue
        attachment_row_write(
            id, att.get("object", ""), att.get("name", ""), att.get("size", 0),
            att.get("content_type", ""), att.get("creator", ""), att.get("caption", ""),
            att.get("description", ""), att.get("rank", 0),
            att.get("created", 0) or mochi.time.now(), att.get("entity", ""))
