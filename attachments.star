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

# The longest filename most filesystems accept for one path component. The id
# and its separator spend 33 bytes of it, and attachment_variant_room reserves
# the rest of what a name may not use.
attachment_component_maximum = 255

# Room for the longest variant infix, "_thumbnail". A variant's cache entry is
# the file name with the kind spliced in, so a name budgeted to the component
# limit exactly produced variant names past it - rendering a long-named
# image's thumbnail aborted the serve, and dropping one aborted the delete.
attachment_variant_room = len("_thumbnail")

# Ranks are database integers, and Starlark's are arbitrary precision, so the
# ceiling matters as much as the floor: core bounded both through sl.AsInt32 and
# a value beyond that cannot be bound as a parameter at all.
attachment_position_maximum = 2147483647

# The bounds the reduce helpers hold peer text and numbers to.
attachment_name_maximum = 255
attachment_text_maximum = 1000

# The largest integer the database binds.
attachment_number_maximum = 9223372036854775807

# The most rows one attachment_store call files. One event may claim any
# number, each an insert; a bulk import stays far under this, and a peer
# spending our disk row by row does not. The truncation is logged, never
# silent.
attachment_store_maximum = 1000

# attachment_backoff_seconds is how long a failed pull suppresses retries. Not a
# tombstone: after it elapses the next access tries again, so a peer that comes
# back (or a lagging host that upgrades) heals without intervention.
attachment_backoff_seconds = 300

# The largest attachment attachment_data will build as a Starlark value. Not a
# storage limit - it bounds one function that has to hold what it returns.
attachment_memory_maximum = 64 * 1024 * 1024

# The storage filename for an attachment: the id, a separator, and the cleaned
# name - readable on disk for debugging, unique and sweep-parseable through the
# id. Core's mochi.file.clean owns the rules, and shares its implementation
# with the validator every file API applies, so a name this returns cannot be
# refused later. A predecessor sanitised by hand in Starlark, predicting what
# the Go validator would accept, and predicted wrongly: every non-ASCII name -
# anyone naming a file in their own language - failed after the bytes were
# already streamed to disk.
def attachment_filename(id, name):
    return id + "_" + mochi.file.clean(name, attachment_component_maximum - len(id) - 1 - attachment_variant_room)

# attachment_name is the canonical form of a client-supplied name, applied once
# where a name enters the library - upload, create, receive, store - so the
# name column, the response dicts, the P2P rows and the disk suffix all hold
# the same string and every consumer downstream inherits its safety. For any
# ordinary name in any script this is the identity.
def attachment_name(name):
    if type(name) != "string":
        name = str(name)
    return mochi.file.clean(name, attachment_component_maximum - 33 - attachment_variant_room)

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

# attachment_row_append writes a row at the end of object's order, choosing the
# rank inside the insert rather than reading it first. Two statements - read the
# maximum, then write it back - can interleave with another request doing the
# same, and both then claim the same rank; handlers are not serialised per user,
# so two uploads to one object race on every save. One statement cannot.
def attachment_row_append(id, object, name, size, content_type, creator, caption, description, created, entity):
    mochi.db.execute(
        """insert into attachments ( id, object, entity, name, size, content_type, creator, caption, description, rank, created )
           values ( ?, ?, ?, ?, ?, ?, ?, ?, ?, ( select coalesce( max( rank ), 0 ) + 1 from attachments where object=? ), ? )""",
        id, object, entity, name, size, content_type, creator, caption, description, object, created)

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

    # Every file before any row. Bytes stream one file at a time, and a
    # builtin error mid-upload aborts the handler with no cleanup - so with
    # rows written per file, three of five uploads succeeding left three
    # committed rows attached to an object the aborted handler never wrote.
    # Files first makes the benign failure orphan files (swept later), and the
    # single transaction below makes the rows all or nothing.
    files = a.files(field)
    stored = []
    for i in range(len(files)):
        meta = files[i]
        # Canonical at the boundary: the browser sends whatever the user's own
        # filesystem allowed, and this is the one name everything downstream -
        # column, disk, responses, P2P rows - will carry.
        name = attachment_name(meta["name"])
        id = mochi.uid()
        # Bounded against core's own figure rather than a copy of it. An
        # attachment above what a transfer carries is kept whole by its owner
        # and received as a prefix by every subscriber, silently.
        size = a.upload(field, attachment_filename(id, name), index=i, maximum=mochi.file.maximum())
        content_type = meta.get("content_type", "")
        if not content_type:
            content_type = attachment_content_type(name)
        stored.append({
            "id": id, "name": name, "size": size, "content_type": content_type,
            "caption": captions[i] if i < len(captions) else "",
            "description": descriptions[i] if i < len(descriptions) else "",
        })

    if not stored:
        return []

    # One transaction for the whole set. The rank subquery sees the rows this
    # transaction already inserted, so the set lands in upload order, and no
    # concurrent save can interleave its ranks into ours.
    created = mochi.time.now()
    handle = mochi.db.transaction()
    for attachment in stored:
        handle.execute(
            """insert into attachments ( id, object, entity, name, size, content_type, creator, caption, description, rank, created )
               values ( ?, ?, '', ?, ?, ?, ?, ?, ?, ( select coalesce( max( rank ), 0 ) + 1 from attachments where object=? ), ? )""",
            attachment["id"], object, attachment["name"], attachment["size"], attachment["content_type"],
            creator, attachment["caption"], attachment["description"], object, created)
    handle.commit()

    results = [attachment_map(attachment_row(attachment["id"]), prefix, "") for attachment in stored]
    attachment_sweep()
    return results

# attachment_create(object, name, data, content_type="", caption="",
# description="", id="", entity="") stores an attachment from bytes already in
# hand (a copy, a decoded payload). Pass id to preserve an existing identifier
# (federation), entity for a remote-provenance row.
def attachment_create(object, name, data, content_type="", caption="", description="", id="", entity=""):
    name = attachment_name(name)
    # A caller-supplied id is a federated one, off a P2P event, and it is held
    # to the same shape attachment_store holds it to: the id addresses the
    # bytes on disk, so a malformed one either collides or poisons the whole
    # filename. Never substituted - an id that changes here no longer matches
    # the one every other host knows this attachment by.
    if id and not attachment_identifier(id):
        mochi.log.debug("attachment_create refusing %s: malformed identifier", name)
        return None
    # A remote-provenance row records where bytes live, and carries none; the
    # entity+data combination silently discarded the bytes while recording
    # their length, so it is refused rather than half-honoured.
    if entity and data:
        mochi.log.debug("attachment_create refusing %s: a remote row carries no bytes", name)
        return None
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
    attachment_row_append(id, object, name, len(data), content_type, "", caption, description, mochi.time.now(), entity)
    return attachment_map(attachment_row(id), mochi.app.url(), "")

# attachment_receive(object, name, stream, content_type="", id="") stores an
# attachment whose bytes arrive on an open stream (a source pulling an upload
# from a replica, or a subscriber pushing one). Streams straight to file
# storage - no whole-file buffering - and records an own row (entity "").
# Returns the response dict, or None if the stream carried nothing. Pass id to
# preserve a federated identifier; creator, caption and description carry the
# uploader's annotations onto the row.
def attachment_receive(object, name, stream, content_type="", id="", creator="", caption="", description=""):
    name = attachment_name(name)
    # Same rule as attachment_create: a federated id is validated, never
    # substituted. wikis passes one straight off a P2P event.
    if id and not attachment_identifier(id):
        mochi.log.debug("attachment_receive refusing %s: malformed identifier", name)
        return None
    if not id:
        id = mochi.uid()
    if not content_type:
        content_type = attachment_content_type(name)
    filename = attachment_filename(id, name)
    # A read that fails aborts the handler, so reaching here means the transfer
    # succeeded - and a transfer of nothing is an empty file, which is a
    # legitimate thing to attach. Treating zero as failure deleted it and
    # reported nothing received, indistinguishable from a broken stream.
    #
    # The same ceiling as the upload path: this is the P2P way for bytes to
    # arrive, and it was the one entry bounded only by the sender's patience
    # and the user's remaining quota. Core cuts one byte past the ceiling, so
    # an oversized transfer is detectable here rather than truncated into a
    # file that looks whole.
    size = stream.read.file(filename, maximum=mochi.file.maximum())
    if size > mochi.file.maximum():
        mochi.log.debug("attachment_receive refusing %s: transfer exceeds the object limit", name)
        mochi.file.delete(filename)
        return None
    attachment_row_append(id, object, name, size, content_type, creator, caption, description, mochi.time.now(), "")
    return attachment_map(attachment_row(id), mochi.app.url(), "")

# attachment_insert(object, name, data, position, content_type="", caption="",
# description="") stores an attachment from bytes at a specific 1-based rank,
# shifting later attachments down. Returns the response dict.
def attachment_insert(object, name, data, position, content_type="", caption="", description=""):
    if len(data) > mochi.file.maximum():
        mochi.log.debug("attachment_insert refusing %s: %d bytes exceeds the object limit", name, len(data))
        return None
    if not attachment_position(position):
        return None
    # A position past the end is an append, not a hole: filed as given, the
    # shift below matches nothing and the row lands beyond its neighbours,
    # leaving a gap the next insert falls into. The count is read just before
    # the transaction; a concurrent insert can age it by one, which costs a
    # one-off gap where the unclamped path cost an arbitrary one.
    count = mochi.db.row("select count(*) as total from attachments where object=?", object)["total"]
    if position > count + 1:
        position = count + 1
    id = mochi.uid()
    if not content_type:
        content_type = attachment_content_type(name)
    mochi.file.write(attachment_filename(id, name), data)
    # Shift and insert as one unit: separately, a concurrent insert at the same
    # position shifts against a list the first has already moved, and both land
    # on the same rank.
    handle = mochi.db.transaction()
    handle.execute("update attachments set rank = rank + 1 where object=? and rank >= ?", object, position)
    handle.execute(
        "insert into attachments ( id, object, entity, name, size, content_type, creator, caption, description, rank, created ) values ( ?, ?, '', ?, ?, ?, '', ?, ?, ?, ? )",
        id, object, name, len(data), content_type, caption, description, position, mochi.time.now())
    handle.commit()
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
    # Remove and shift as one unit, for the same reason insert and move do:
    # interleaved with either, a bare pair leaves the order decided by
    # whichever statement landed last.
    handle = mochi.db.transaction()
    handle.execute("delete from attachments where id=?", id)
    handle.execute("update attachments set rank = rank - 1 where object=? and rank > ?", row["object"], row["rank"])
    handle.commit()
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
    if not attachment_position(position):
        return None
    row = attachment_row(id)
    if not row:
        return None
    # A move past the end means last. A move does not grow the list, so the
    # ceiling is the count itself, and the row being moved guarantees it is at
    # least one.
    count = mochi.db.row("select count(*) as total from attachments where object=?", row["object"])["total"]
    if position > count:
        position = count
    old = row["rank"]
    new = position
    if old != new:
        # Shift and set as one unit, for the same reason the insert above is:
        # two moves interleaving shift each other's ranges and leave the order
        # decided by whichever statement landed last.
        handle = mochi.db.transaction()
        if new < old:
            handle.execute("update attachments set rank = rank + 1 where object=? and rank >= ? and rank < ?", row["object"], new, old)
        else:
            handle.execute("update attachments set rank = rank - 1 where object=? and rank > ? and rank <= ?", row["object"], old, new)
        handle.execute("update attachments set rank=? where id=?", new, id)
        handle.commit()
    return attachment_map(attachment_row(id), mochi.app.url(), "")

# attachment_position reports whether a caller-supplied position is a usable
# rank SHAPE: an integer from 1, which core required and this did not - a zero
# or negative one puts a row below the floor every other query assumes. The
# other hazard, a position far past the end, is not this function's to judge
# because it depends on the object: insert and move clamp against their own
# list, to append and to last.
def attachment_position(position):
    if type(position) != "int" or position < 1 or position > attachment_position_maximum:
        mochi.log.debug("attachment position %s is not a rank", str(position))
        return False
    return True

def attachment_update(id, caption, description):
    if not attachment_exists(id):
        return None
    mochi.db.execute("update attachments set caption=?, description=? where id=?", caption, description, id)
    return attachment_map(attachment_row(id), mochi.app.url(), "")

# attachment_copy(id, object, requester="", caption="", description="") duplicates an
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
def attachment_copy(id, object, requester="", caption="", description=""):
    row = attachment_row(id)
    if not row:
        return None

    new = mochi.uid()
    name = row["name"]
    destination = attachment_filename(new, name)

    if row.get("entity"):
        if not attachment_pull(id, row, requester):
            return None
        size = mochi.cache.copy(attachment_cache_name(id), destination)
    else:
        # Same guard as attachment_data: the copy primitive raises on a
        # missing source, and a row whose file is gone should degrade, not
        # abort.
        source = attachment_filename(id, name)
        if not mochi.file.exists(source):
            return None
        size = mochi.file.copy(source, destination)
    if size == None:
        return None

    attachment_row_append(new, object, name, size, row.get("content_type", ""), "",
                          caption, description, mochi.time.now(), "")
    return attachment_map(attachment_row(new), mochi.app.url(), "")

# attachment_fetch(id, requester="") makes sure a remote attachment's bytes are in
# cache, returning whether they are available. For a row we hold locally there
# is nothing to do. Callers that only want to warm the cache use this rather
# than attachment_data, whose return value they would discard - and which would
# read the whole object into memory to produce it.
def attachment_fetch(id, requester=""):
    row = attachment_row(id)
    if not row:
        return False
    if not row.get("entity"):
        return True
    return attachment_pull(id, row, requester)

# attachment_entry(id, name, requester="") returns a mochi.archive.write entry naming
# this attachment's bytes, or None if they cannot be obtained. Pair it with
# attachment_extract on the way back in. This is how an export carries
# attachments: the archive streams each one straight off disk, where embedding
# them in the export's own JSON meant holding every one of them, base64-expanded
# by a third, in memory at the same time.
#
# A remote copy is pulled into cache first and referenced there, so exporting a
# subscribed container's attachments does not first turn them into ours.
def attachment_entry(id, name, requester=""):
    row = attachment_row(id)
    if not row:
        return None
    if row.get("entity"):
        if not attachment_pull(id, row, requester):
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
    attachment_row_append(id, object, name, size, content_type, "", caption, description,
                          mochi.time.now(), "")
    return attachment_map(attachment_row(id), mochi.app.url(), "")

# attachment_data(id, requester="") returns an attachment's bytes, or None. For an own
# row it reads local storage; for a remote row it pulls from the source on
# demand (as the old mochi.attachment.data did) and returns the cached copy.
# requester is the requesting user's identity, needed to open the pull stream - pass
# it (a.user.identity.id) when the row may be remote (copy, export). Used by
# paths that need the bytes in hand.
def attachment_data(id, requester=""):
    row = attachment_row(id)
    if not row:
        return None
    # An attachment may be as large as the uploader's whole quota, and this is
    # the one path that materialises it as a Starlark value - in a process every
    # user on the host shares. Callers moving bytes rather than inspecting them
    # want attachment_copy or attachment_entry, which stream.
    #
    # The limit goes to the primitive rather than being checked against the row
    # first. A row's size is a claim, and for a remote row it is the peer's
    # claim: bounding on it meant a peer declaring nothing could have any amount
    # of cache read into memory behind a limit that had already been satisfied.
    # Only the file knows how big the file is.
    if row.get("entity"):
        if not attachment_pull(id, row, requester):
            return None
        return mochi.cache.read(attachment_cache_name(id), maximum=attachment_memory_maximum)
    # The file primitives raise on a missing source, which Starlark cannot
    # catch, so the documented "or None" held for the cache path and not this
    # one: an orphaned row turned a graceful degrade into an abort. The guard
    # has a race window, but its loser merely aborts as every reader did
    # before; os.Root owns safety.
    filename = attachment_filename(id, row["name"])
    if not mochi.file.exists(filename):
        return None
    return mochi.file.read(filename, maximum=attachment_memory_maximum)

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

# attachment_forget drops an attachment's cache entries: a remote copy's
# original and variants, and an own image's rendered variants.
def attachment_forget(row):
    if row.get("entity"):
        mochi.cache.delete(attachment_cache_name(row["id"], ""))
        mochi.cache.delete(attachment_cache_name(row["id"], "thumbnail"))
        mochi.cache.delete(attachment_cache_name(row["id"], "preview"))
        return
    # An own image's rendered variants live in cache under a name derived from
    # the file's - deterministic, so a deleted private image's thumbnail is
    # dropped now rather than lingering until eviction. The derivation mirrors
    # core's variant naming; the test suite holds the two equal against what
    # mochi.image.variant actually returns, so a rename there fails loudly
    # instead of silently orphaning variants again.
    if attachment_is_image(row["name"]):
        filename = attachment_filename(row["id"], row["name"])
        mochi.cache.delete("variants/" + attachment_variant_name(filename, "thumbnail"))
        mochi.cache.delete("variants/" + attachment_variant_name(filename, "preview"))

# The cache entry stem core's variant renderer uses: the file name with the
# kind spliced in ahead of the extension.
def attachment_variant_name(filename, kind):
    extension = ""
    index = filename.rfind(".")
    if index >= 0:
        extension = filename[index:]
        filename = filename[:index]
    return filename + "_" + kind + extension

# ---------------------------------------------------------------------------
# HTTP serving (the action is the gate)
# ---------------------------------------------------------------------------

# attachment_serve(a, id, container, variant="", member=None) serves an
# attachment's bytes (or an image variant) to the HTTP response. THE CALLING
# ACTION IS THE GATE: it must authorize the requester against container before
# calling, and check-attachment-access.py enforces that a gate is visible in
# the enclosing function. An authorize callback used to be a required argument
# here, meant to make the ungated shape inexpressible - five of six apps
# passed lambda: True because they had already gated, which reduced the
# parameter to ceremony the grep gate could not tell from substance. The
# binding stays: the attachment must belong to container - directly, or
# through member(object) -> bool for attachments on the container's children
# (a wiki's comments) - so one container's route cannot fetch another's
# attachment by id. Writes an error label on absence.
def attachment_serve(a, id, container, variant="", member=None, adopt=False):
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
    # The served content type derives from the attachment's NAME on every
    # branch, never from the row's content_type column. For a remote row that
    # column is the peer's claim, and while the safe-serve policy confines the
    # damage, it still let a peer choose inline PDF rendering for arbitrary
    # bytes. The local file branch always derived from the name; the cache
    # branches pass the same derivation explicitly, because a remote cache
    # entry is named by id alone and carries no extension for core to read.
    kind = mochi.file.type(row["name"])
    if row.get("entity"):
        requester = a.user.identity.id if (a.user and a.user.identity) else container
        # The container's canonical holder passes adopt=True: a remote row in
        # its store is a legacy of the uploader-keeps-the-bytes scheme, healed
        # here by taking the bytes in on first serve. Subscribers keep pulling
        # to cache - adopting there would replicate every attachment to every
        # subscriber's permanent storage. The adopt pull opens as the container
        # entity, not the viewer: the uploader's responder recognises the
        # container it holds the upload for, while a viewer's identity means
        # nothing on that host.
        if adopt and attachment_adopt(id, container):
            row = attachment_row(id)
        else:
            want = variant if (variant and attachment_is_image(row["name"])) else ""
            if want and attachment_pull(id, row, requester, want):
                a.write.cache(attachment_cache_name(id, want), content_type=kind)
                return
            if attachment_pull(id, row, requester, ""):
                a.write.cache(attachment_cache_name(id, ""), content_type=kind)
                return
            a.error.label(404, "attachment.errors.not_found")
            return

    # Own row: serve the original from file storage, or an image variant which
    # mochi.image.variant renders into cache on demand.
    if variant and attachment_is_image(row["name"]):
        name = mochi.image.variant(attachment_filename(id, row["name"]), variant)
        if name and a.write.cache(name, content_type=kind):
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
    # The payload may not even be a sequence: every app passes
    # e.content("attachments") straight in, and a peer sending a scalar would
    # abort the DOMAIN handler mid-iteration - the comment or message lost,
    # not just its attachments. The dict test below never caught this, because
    # iteration itself is what raises. Both sequence shapes are legitimate: a
    # local caller builds a list, and core decodes every wire array to a
    # tuple - a list-only test here silently zeroed every P2P store.
    if type(rows) not in ["list", "tuple"]:
        return 0
    if len(rows) > attachment_store_maximum:
        mochi.log.debug("attachment_store truncating %d rows to %d", len(rows), attachment_store_maximum)
        rows = rows[:attachment_store_maximum]
    count = 0
    for attachment in rows:
        if type(attachment) != "dict":
            continue
        id = attachment.get("id")
        if not attachment_identifier(id):
            continue
        target = object if object != None else attachment.get("object", "")
        if type(target) != "string" or not target:
            continue
        if attachment_conflict(id, target):
            continue

        # A peer's name is a claim like the rest of its row: the same canonical
        # form the local paths apply, so nothing peer-shaped reaches the disk
        # name or a Content-Disposition header.
        name = attachment_name(attachment_text(attachment.get("name", ""), attachment_name_maximum))
        size = attachment_number(attachment.get("size", 0))
        content_type = attachment_text(attachment.get("content_type", ""), attachment_name_maximum)
        caption = attachment_text(attachment.get("caption", ""), attachment_text_maximum)
        description = attachment_text(attachment.get("description", ""), attachment_text_maximum)
        # Ranks start at 1; zero is what attachment_number reduces everything
        # unusable to, and it doubles here as the sentinel for "the row named
        # no usable position" - absent, zero, negative, or past the integer
        # the column holds. Such a row appends rather than landing below the
        # floor every ordering query assumes.
        rank = attachment_number(attachment.get("rank", 0))
        if rank > attachment_position_maximum:
            rank = 0

        # An id we already hold under this object is an annotation update, and
        # the row's fields divide by what they mean rather than by what looks
        # dangerous. name, size and content_type describe WHICH BYTES these are;
        # entity, creator and created describe where they came from. Neither is
        # the sender's to restate, and name least of all: the bytes live at
        # attachment_filename(id, name), so changing it moves the address
        # without moving the file. Nine call sites then read a path that does
        # not exist - serving, the responder, copy, export, both variants - and
        # a later delete unlinks the new name and drops the row, orphaning the
        # real file under the old one.
        #
        # What remains is what an annotation is: caption, description, and the
        # position in the object's order. A restatement that tries to change the
        # rest updates these and leaves the rest alone, so a genuine re-broadcast
        # is idempotent and a hostile one is inert.
        existing = attachment_row(id)
        if existing:
            # A restatement may only annotate a row whose provenance matches
            # the sender's. The conflict guard above holds the OBJECT, and
            # identity immutability holds the bytes - but a row with entity ''
            # is one WE created, and a peer quoting its id could still rewrite
            # our caption, description and order. Which bytes these are was
            # never the sender's to restate; that where-they-came-from decides
            # whether they may restate at all closes the remainder.
            if existing.get("entity", "") != entity:
                continue
            mochi.db.execute(
                "update attachments set caption=?, description=?, rank=? where id=?",
                caption, description,
                rank if rank else existing.get("rank", 1), id)
            count = count + 1
            continue

        # A row without a usable rank appends, choosing the position inside
        # the insert for the same reason attachment_row_append does: two
        # events landing rows on one object race on any read-then-write.
        mochi.db.execute(
            """insert into attachments ( id, object, entity, name, size, content_type, creator, caption, description, rank, created )
               values ( ?, ?, ?, ?, ?, ?, ?, ?, ?, coalesce( nullif( ?, 0 ), ( select coalesce( max( rank ), 0 ) + 1 from attachments where object=? ) ), ? )""",
            id, target, entity, name, size, content_type,
            attachment_text(attachment.get("creator", ""), attachment_name_maximum),
            caption, description, rank, target,
            attachment_number(attachment.get("created", 0)) or mochi.time.now())
        count = count + 1
    return count

# A peer's row is data, not a promise about its own shape. The three helpers
# below reduce each field to the type the rest of the library assumes, because
# the caller's authorisation answers whether this peer may send us anything at
# all - not whether what arrived is well formed. A field of the wrong type is
# not inert: a name that is a number reaches name.lower() in
# attachment_is_image and aborts the handler, which Starlark gives no way to
# recover from.

# attachment_identifier reports whether id is a well formed attachment id: 32
# characters of lowercase alphanumeric, matching what core accepts. A malformed
# one cannot address anything - it becomes a cache name core's own path check
# refuses - so the row would never resolve and is dropped instead.
# One alphabet for attachment ids: mochi.uid() is a UUID with the hyphens
# removed, so every id ever minted is 32 lowercase hex characters. This used
# to admit the full lowercase alphanumerics while the sweep's attachment_hex
# admitted only hex - two rules for the same identifier, disagreeing on rows
# neither could have created.
def attachment_identifier(id):
    return type(id) == "string" and len(id) == 32 and attachment_hex(id)

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
    if kind == "float":
        value = int(value)
    elif kind != "int":
        return 0
    if value < 0:
        return 0
    # Starlark integers are arbitrary precision and one past the database's
    # cannot be bound as a parameter at all, so an absurd number would abort
    # the statement rather than store large. This is the general bound - sizes
    # legitimately exceed 32 bits - and ranks are clamped tighter where they
    # are read.
    if value > attachment_number_maximum:
        return 0
    return value

# ---------------------------------------------------------------------------
# Byte transfer (requester and responder)
# ---------------------------------------------------------------------------

def attachment_backoff_name(id, variant=""):
    if variant:
        return "backoff/" + id + "_" + variant
    return "backoff/" + id

# attachment_pull(id, row, variant="") ensures a remote attachment's bytes (the
# original, or an image variant the source renders) are in the cache, requesting
# them from the container's source when absent. Returns True if present
# afterwards. Applies time-based backoff on failure. The source is the row's
# provenance entity (app state), never a field a response claims.
def attachment_pull(id, row, requester, variant=""):
    name = attachment_cache_name(id, variant)
    if mochi.cache.path(name):
        return True
    age = mochi.cache.age(attachment_backoff_name(id, variant))
    if age != None and age < attachment_backoff_seconds:
        return False  # still within the backoff window; not a tombstone

    entity = row.get("entity", "")
    if not entity or not requester:
        mochi.log.debug("attachment_pull %s: no entity (%s) or requester (%s)", id, entity, requester)
        return False
    # `requester` is the local entity opening the stream - the requesting user's
    # identity (which the responder authorizes) for an authenticated pull, or
    # the container's route entity for an anonymous public one. `to` is the
    # source from app state (the row's provenance), never a field a response
    # claims. The frame routes by SERVICE: the app's declared one, which for
    # most apps happens to equal the URL path prefix this used to send - a
    # coincidence that breaks for any app shaped like comptroller (paths
    # ["comptroller"], services ["market"]).
    services = mochi.app.services()
    stream = mochi.stream(
        {"from": requester, "to": entity, "service": services[0] if services else mochi.app.url(), "event": "attachment/fetch"},
        {"id": id, "object": row["object"], "variant": variant})
    ok = False
    if not stream:
        mochi.log.debug("attachment_pull %s: stream open to %s failed", id, entity)
    if stream:
        response = stream.read()
        if not response or response.get("status") != "200":
            mochi.log.debug("attachment_pull %s: response %s", id, str(response))
        if response and response.get("status") == "200":
            # Bound the transfer to the size the row declares, so a peer
            # answering a 1 KB pull cannot push gigabytes through the disk
            # before the size check runs. A variant is rendered by the source
            # and declares nothing, so it keeps the global cap. Core cuts one
            # byte past the bound; an overrun therefore arrives as declared+1
            # and fails the exactness check below.
            declared = int(row.get("size", 0))
            written = mochi.cache.write(name, stream, maximum=0 if variant else declared)
            if attachment_complete(written, declared, variant):
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
    if variant:
        return True
    # A row declaring nothing used to accept anything, which is the whole of a
    # size check handed to the sender. Zero is a legitimate declaration - an
    # empty file is a real attachment - so the answer is not to refuse it but to
    # hold it to its word.
    if declared == 0:
        return written == 0
    if declared < 0:
        return False
    # Exact, in both directions. The source is streaming a file it owns whose
    # size the row records; there is no honest way for the two to differ. Less
    # is a truncated transfer, and more is a peer padding the body - which the
    # transfer bound cuts to declared+1 exactly so it lands here as an
    # overrun rather than as a silently truncated "complete" file. A slack of
    # 2x used to be accepted here, with nothing that could legitimately
    # produce it.
    return written == declared

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
    # The id and variant are the peer's claims, and both feed functions that
    # abort on a bad shape - the variant goes to mochi.image.variant, which
    # raises for anything but its two kinds, so an unvalidated one let a peer
    # kill our responder with a single word.
    id = e.content("id")
    if not attachment_identifier(id):
        e.write({"status": "400"})
        return
    if e.content("variant", "") not in ["", "thumbnail", "preview"]:
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

# attachment_push(container, object, stored, requester) streams locally saved
# attachments to container's owner, one attachment/push stream per file:
# metadata in the opening frame, the bytes, then the owner's ack. The owner is
# canonical - it stores the bytes as its own and fans the metadata out - so a
# row only ever exists downstream of the bytes it describes. Returns True when
# every attachment is acknowledged; the first failure stops the batch and the
# caller unwinds its local saves, because a "successful" upload nobody else can
# see is the failure this scheme exists to remove. The uploader's own rows stay
# entity "" with the file on disk: it legitimately holds the bytes, and the
# owner's later fan-out restatement is inert against them.
def attachment_push(container, object, stored, requester):
    if not requester:
        return False
    # Route by the app's declared service, not its URL prefix - the same
    # comptroller-shaped distinction attachment_pull carries.
    services = mochi.app.services()
    service = services[0] if services else mochi.app.url()
    for attachment in stored:
        id = attachment["id"]
        stream = mochi.stream(
            {"from": requester, "to": container, "service": service, "event": "attachment/push"},
            {"object": object, "id": id, "name": attachment["name"],
             "size": attachment.get("size", 0),
             "content_type": attachment.get("type") or attachment.get("content_type", ""),
             "caption": attachment.get("caption", ""),
             "description": attachment.get("description", "")})
        if not stream:
            return False
        # Two phases, strictly alternating: the owner judges the metadata and
        # answers before any byte moves, and only then do the bytes flow. A
        # single-phase push deadlocked against a refusal - the responder
        # blocked writing its status into a pipe nobody was reading while this
        # side blocked writing bytes into the same, and both sat out their
        # timeouts. With the go-ahead read here, whichever side is writing,
        # the other is reading. A 200 at the go-ahead is the retry case: the
        # owner already holds this attachment, and the bytes stay home.
        response = stream.read()
        status = response.get("status") if response else ""
        if status == "200":
            continue
        if status != "100":
            return False
        # write.file closes the write side when the bytes are sent, so the ack
        # read below is unambiguous: the owner answers after its row exists.
        written = stream.write.file(attachment_filename(id, attachment["name"]))
        if written == None:
            return False
        response = stream.read()
        if not response or response.get("status") != "200":
            return False
    return True

# attachment_push_receive(e, object, creator="") answers one attachment/push
# stream: validate the metadata claims, stream the bytes to file storage, write
# the own row, ack. AUTHORIZATION IS THE CALLING HANDLER'S: it verified the
# signed sender holds write access on the container and that object belongs to
# it before calling, exactly as the HTTP upload action gates its own request.
# Returns the response dict, or None with the refusal already written.
def attachment_push_receive(e, object, creator=""):
    id = e.content("id")
    if not attachment_identifier(id):
        e.write({"status": "400"})
        return None
    # An id bound to another object must not be repointed (attachment_store's
    # rule); one already bound to THIS object is a retry of a push whose ack
    # was lost, and answering 200 without touching anything makes the retry
    # safe rather than a duplicate.
    if attachment_conflict(id, object):
        e.write({"status": "409"})
        return None
    if attachment_exists(id):
        e.write({"status": "200"})
        return attachment_map(attachment_row(id), mochi.app.url(), "")
    name = attachment_name(attachment_text(e.content("name", ""), attachment_name_maximum))
    if not name:
        e.write({"status": "400"})
        return None
    content_type = attachment_text(e.content("content_type", ""), attachment_name_maximum)
    caption = attachment_text(e.content("caption", ""), attachment_text_maximum)
    description = attachment_text(e.content("description", ""), attachment_text_maximum)
    # Go-ahead: the metadata passed judgement, so invite the bytes. The pusher
    # reads this before writing them (see attachment_push on why the phases
    # must alternate).
    e.write({"status": "100"})
    attachment = attachment_receive(object, name, e, content_type, id,
                                    creator=creator, caption=caption, description=description)
    if not attachment:
        e.write({"status": "400"})
        return None
    e.write({"status": "200"})
    return attachment

# attachment_accept(rows, sender, object, requester="") is the owner-side
# counterpart of a metadata-carrying content submission: store the rows as
# attachment_store does, then immediately take each one's bytes in from the
# sender, who is by definition just-online. A pull that fails leaves that row
# remote-provenance, and the canonical holder's adopt-on-serve heals it later -
# the submission itself is never rejected over its attachments. requester is
# the identity the pull streams open as; the container's own entity is the
# natural one, since the sender-side responder recognises the container it
# holds the upload for. Returns the count stored.
def attachment_accept(rows, sender, object, requester=""):
    count = attachment_store(rows, sender, object)
    if type(rows) in ["list", "tuple"]:
        for attachment in rows[:attachment_store_maximum]:
            if type(attachment) == "dict" and attachment_identifier(attachment.get("id")):
                attachment_adopt(attachment["id"], requester)
    return count

# attachment_adopt(id, requester="") turns a remote-provenance row into an own
# one: pull the original into cache, copy it into file storage under the name
# every other host already knows, and flip the row. The size is re-recorded
# from the copy - the row's figure was the peer's claim, and the completeness
# check in attachment_pull held the transfer to it, so the two agree or the
# pull already failed. Idempotent: an own row is already adopted. This is how
# the canonical holder of a container heals rows minted under the old
# uploader-keeps-the-bytes scheme without a migration pass - the first serve
# adopts, every later one reads a local file.
def attachment_adopt(id, requester=""):
    row = attachment_row(id)
    if not row:
        return False
    if not row.get("entity"):
        return True
    if not attachment_pull(id, row, requester):
        return False
    size = mochi.cache.copy(attachment_cache_name(id), attachment_filename(id, row["name"]))
    if size == None:
        return False
    mochi.db.execute("update attachments set entity='', size=? where id=?", size, id)
    # The remote-name cache entries are orphans once the row is ours; variants
    # re-render from the file under their own naming.
    attachment_forget(row)
    return True

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
    files = mochi.file.list("")
    if not files:
        return
    # One query for the whole pass. Testing each candidate with its own
    # attachment_exists made every upload pay a query per stored file - for a
    # user with thousands of attachments in one app, thousands of round trips
    # per save, spent looking for orphans that almost never exist.
    held = {row["id"]: True for row in mochi.db.rows("select id from attachments")}
    for entry in files:
        filename = entry
        under = filename.find("_")
        if under <= 0:
            continue
        id = filename[:under]
        # An attachment id is a 32-character hex uid (mochi.uid with the UUID
        # hyphens removed); anything else is some other app file, left alone.
        if len(id) != 32 or not attachment_hex(id):
            continue
        if id in held:
            continue
        # A disk name the validator refuses was written under an older rule;
        # mochi.file.age would abort the handler on it, and one such file must
        # not cost the user every future upload. Left alone rather than deleted:
        # refusing to sweep a name is safe, deleting it is not.
        if not mochi.text.valid(filename, "filepath"):
            continue
        settled = mochi.file.age(filename)
        if settled == None or settled < age:
            continue
        mochi.file.delete(filename)

# attachment_hex reports whether every character is a lowercase hex digit, so
# the orphan sweep only touches uid-shaped names.
def attachment_hex(text):
    for i in range(len(text)):
        if text[i] not in "0123456789abcdef":
            return False
    return True

# ---------------------------------------------------------------------------
# Migration (transition bridge)
# ---------------------------------------------------------------------------

# Where core materialised each user's attachment rows before it dropped its own
# store: one JSON list per (user, app), at the root of the app's file storage,
# written only where rows existed. The name is not uid-shaped, so the orphan
# sweep never touches it. Each entry carries the columns an attachment row
# holds plus "file", the stored filename of an own row ("" for a remote one).
attachment_export_file = "attachments.json"

# attachment_export() returns the rows core's store held for this user and app:
# from the bridge while a core still has one, else from the file its cleanup
# wrote, else nothing - a core without the bridge exported every store that had
# rows before it served a request, so no file means no rows. The one hold is an
# export that exists and cannot be read: that is a damaged file, not an empty
# store, so the migration aborts without advancing and an operator sees it.
def attachment_export():
    if hasattr(mochi, "attachment") and hasattr(mochi.attachment, "export"):
        rows = mochi.attachment.export()
        if rows == None:
            mochi.db.abort("attachment bridge unavailable")
            return None
        return rows
    if not mochi.file.exists(attachment_export_file):
        return []
    rows = json.decode(str(mochi.file.read(attachment_export_file) or ""), None)
    if type(rows) != "list":
        mochi.db.abort("attachment export unreadable")
        return None
    return rows

# attachment_migrate() copies attachment rows out of core's store into this
# app's own table, once, from a database_upgrade step. Ids are preserved
# verbatim (URLs and remote references depend on them). Own rows (entity "")
# keep their files in place; remote rows keep pull-on-demand. A core without
# the bridge and without an export for this store has nothing to copy.
def attachment_migrate():
    rows = attachment_export()
    if rows == None:
        return
    for attachment in rows:
        id = attachment.get("id")
        if not id or attachment_exists(id):
            continue
        attachment_row_write(
            id, attachment.get("object", ""), attachment.get("name", ""), attachment.get("size", 0),
            attachment.get("content_type", ""), attachment.get("creator", ""), attachment.get("caption", ""),
            attachment.get("description", ""), attachment.get("rank", 0),
            attachment.get("created", 0) or mochi.time.now(), attachment.get("entity", ""))
