# Mochi shared Starlark library: Attachments
# Copyright © 2026 Mochisoft OÜ
# SPDX-License-Identifier: AGPL-3.0-only
# This file is part of Mochi, licensed under the GNU AGPL v3 with the Mochi
# Application Interface Exception - see license.txt and license-exception.md.
#
# App-owned file attachments: each app vendors this file (a symlink into
# apps/<app>/lib/, listed first in app.json "execute") and owns its attachments
# table. Every definition is prefixed attachment_; the library runs before the
# app's own files, so it references no app global.
#
# Original bytes live in the app's file storage as "<id>_<name>"; image variants
# and remote copies live in cache space and may be evicted.

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

# The most rows one object may carry. attachment_store_maximum bounds a single
# call; without this a peer repeating post/create and comment/create adds
# another batch every time, and attachment_list returns every one of them into a
# page-enrichment loop with a pull behind each remote row.
attachment_object_maximum = 250

# The most rows one attachment_accept adopts. Each adoption opens a synchronous
# P2P stream inside the calling event handler, so this is a far tighter bound
# than the row cap: a submission carrying more keeps its extra rows remote, and
# they are pulled on demand when they are first served.
attachment_adopt_maximum = 32

# attachment_backoff_seconds is how long a failed pull suppresses retries. Not a
# tombstone: after it elapses the next access tries again, so a peer that comes
# back (or a lagging host that upgrades) heals without intervention.
attachment_backoff_seconds = 300

# How often one user's orphan sweep runs for an app, and the cache marker whose
# age keeps the count. The sweep lists the whole file root and queries every
# row, a cost that scales with the store, and it used to be paid on every
# upload for orphans that almost never exist.
attachment_sweep_seconds = 3600
attachment_sweep_marker = "sweep"

# The largest image variant a pull accepts. A variant declares no size, so
# nothing else bounds it: without a ceiling the source could stream core's
# 10 GB object maximum and it would be kept and served as the thumbnail.
attachment_variant_maximum = 16 * 1024 * 1024

# attachment_room is the name length a filename can hold once the id and its
# separator are taken out. Both helpers below derive from it, so they cannot
# drift: attachment_name runs before the id exists and assumes the id length
# attachment_identifier pins, while attachment_filename measures the real one.
# The floor matters because mochi.file.clean SILENTLY RESETS a maximum below 16
# to 255, which would put the path component past the filesystem limit.
attachment_identifier_length = 32

def attachment_room(length):
    room = attachment_component_maximum - length - 1 - attachment_variant_room
    return room if room >= 16 else 16

# Storage filename: the id, a separator, and the cleaned name. Cleaning is
# core's mochi.file.clean, which shares its implementation with the validator
# every file API applies - a hand-rolled sanitiser cannot predict what it takes.
def attachment_filename(id, name):
    return id + "_" + mochi.file.clean(name, attachment_room(len(id)))

# attachment_name is the canonical form of a client-supplied name, applied once
# where a name enters the library, so the column, the response dicts, the P2P
# rows and the disk suffix all hold the same string.
def attachment_name(name):
    if type(name) != "string":
        name = str(name)
    return mochi.file.clean(name, attachment_room(attachment_identifier_length))

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

# Writes a row at the end of object's order, choosing the rank inside the
# insert: handlers are not serialised per user, so a read-then-write pair races
# with a concurrent save and both claim the same rank.
def attachment_row_append(id, object, name, size, content_type, creator, caption, description, created, entity):
    mochi.db.execute(
        """insert into attachments ( id, object, entity, name, size, content_type, creator, caption, description, rank, created )
           values ( ?, ?, ?, ?, ?, ?, ?, ?, ?, ( select coalesce( max( rank ), 0 ) + 1 from attachments where object=? ), ? )""",
        id, object, entity, name, size, content_type, creator, caption, description, object, created)

# attachment_url reproduces the URL shapes core built, so the response shape
# apps' web and Android clients consume is unchanged. With an entity: the public
# entity-scoped route /<app>/<entity>/-/attachments/<id>. Without: the
# class-level /<app>/attachments/<id>.
# No app declares a class-level attachments/:id action - every one declares
# only :<entity>/-/attachments/:id - so the entity-less form fell through to the
# SPA catch-all and returned index.html. An absent URL is honest; a caller that
# needs one passes the entity, as attachment_list and attachment_get do.
def attachment_url(prefix, entity, id):
    if not entity:
        return ""
    return "/" + prefix + "/" + entity + "/-/attachments/" + id

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
    url = attachment_url(prefix, entity, row["id"]) if prefix else ""
    if url:
        result["url"] = url
        if image:
            result["thumbnail_url"] = url + "/thumbnail"
            result["preview_url"] = url + "/preview"
    return result

def attachment_row(id):
    return mochi.db.row("select * from attachments where id=?", id)

# Reports whether id already exists bound to a different object. Receive paths
# write peer-chosen ids, and repointing one detaches an attachment from the
# message it belongs to. Same object is an ordinary annotation update.
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

    # Every file before any row. A builtin error mid-upload aborts the handler
    # with no cleanup, so per-file rows leave rows on an object never written;
    # files first orphans bytes instead, and the sweep collects them.
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
        # Bounded like the P2P path's: the browser chooses this string and it
        # reaches the column, the response dicts and the fan-out.
        content_type = attachment_text(meta.get("content_type", ""), attachment_name_maximum)
        if not content_type:
            content_type = attachment_content_type(name)
        # The same ceiling the wire path applies on the way in: a longer local
        # caption was stored whole here and cut to attachment_text_maximum by
        # every replica, so the owner and its replicas held different text.
        stored.append({
            "id": id, "name": name, "size": size, "content_type": content_type,
            "caption": attachment_text(captions[i] if i < len(captions) else "", attachment_text_maximum),
            "description": attachment_text(descriptions[i] if i < len(descriptions) else "", attachment_text_maximum),
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
    attachment_sweep_due()
    return results

# attachment_create(object, name, data, content_type="", caption="",
# description="", id="", entity="") stores an attachment from bytes already in
# hand (a copy, a decoded payload). Pass id to preserve an existing identifier
# (federation), entity for a remote-provenance row.
def attachment_create(object, name, data, content_type="", caption="", description="", id="", entity=""):
    name = attachment_name(name)
    # A federated id is validated, never substituted: the id addresses the bytes
    # on disk, and changing it breaks the identity every other host knows.
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
    # A remote row carries no bytes, and the documented call passes None for
    # them; len() would abort the handler rather than record a zero.
    attachment_row_append(id, object, name, len(data) if data else 0, content_type, "",
                          attachment_text(caption, attachment_text_maximum),
                          attachment_text(description, attachment_text_maximum),
                          mochi.time.now(), entity)
    return attachment_map(attachment_row(id), mochi.app.url(), "")

# attachment_receive(object, name, stream, ..., declared=None) stores an
# attachment whose bytes arrive on an open stream, straight to file storage
# with no whole-file buffering, as an own row (entity ""). Pass id to preserve
# a federated one, and declared - the size the sender's metadata claims - when
# the wire carries one: the transfer is then bounded to it and held to it
# exactly. Core clamps a stream read to the receiver's remaining quota and
# reports no truncation, so without a declaration a transfer cut short there
# is recorded, at its truncated length, as a whole attachment.
def attachment_receive(object, name, stream, content_type="", id="", creator="", caption="", description="", declared=None):
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
    # Zero bytes is an empty file, a legitimate attachment, not a failure. The
    # ceiling is the upload path's, tightened to the declaration when there is
    # one so a sender cannot write the receiver's whole remaining quota before
    # the size check; core cuts one byte past the bound either way, so an
    # oversized transfer is detectable here rather than truncated into a
    # whole-looking file.
    limit = mochi.file.maximum()
    if declared != None and attachment_transfer(declared) < limit:
        limit = attachment_transfer(declared)
    size = stream.read.file(filename, maximum=limit)
    if size > mochi.file.maximum():
        mochi.log.debug("attachment_receive refusing %s: transfer exceeds the object limit", name)
        mochi.file.delete(filename)
        return None
    if declared != None and not attachment_complete(size, declared):
        mochi.log.debug("attachment_receive refusing %s: received %d of a declared %d", name, size, declared)
        mochi.file.delete(filename)
        return None
    attachment_row_append(id, object, name, size, content_type, creator,
                          attachment_text(caption, attachment_text_maximum),
                          attachment_text(description, attachment_text_maximum),
                          mochi.time.now(), "")
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
    return attachment_remove(row)

# attachment_remove(row) is the write half of attachment_delete, taking the
# row the read half found - which may be stale by the time the delete runs,
# as it is for the losing side of two deletes racing on one id. Remove and
# shift as one unit, for the same reason move does: interleaved with a move,
# a bare pair leaves the order decided by whichever statement landed last.
# The delete reports the rank it removed - one statement, so the shift uses
# the rank the row holds at that moment, not the one the read saw - and the
# shift runs only when a row was removed: the loser used to find no row and
# shift the object's ranks a second time, opening a gap in the order for the
# next append to fall into.
def attachment_remove(row):
    handle = mochi.db.transaction()
    removed = handle.row("delete from attachments where id=? returning object, rank", row["id"])
    if not removed:
        handle.rollback()
        return False
    handle.execute("update attachments set rank = rank - 1 where object=? and rank > ?", removed["object"], removed["rank"])
    handle.commit()
    if not row.get("entity"):
        mochi.file.delete(attachment_filename(row["id"], row["name"]))
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

# Reports whether a position is a usable rank shape: an integer from 1. A zero
# or negative one puts a row below the floor every ordering query assumes. A
# position past the end is insert's and move's to clamp against their own list.
def attachment_position(position):
    if type(position) != "int" or position < 1 or position > attachment_position_maximum:
        mochi.log.debug("attachment position %s is not a rank", str(position))
        return False
    return True

def attachment_update(id, caption, description):
    if not attachment_exists(id):
        return None
    mochi.db.execute("update attachments set caption=?, description=? where id=?",
                     attachment_text(caption, attachment_text_maximum),
                     attachment_text(description, attachment_text_maximum), id)
    return attachment_map(attachment_row(id), mochi.app.url(), "")

# attachment_copy(id, object, requester, caption, description) duplicates an
# attachment onto another object, streaming file to file rather than through
# memory. The copy is always ours (entity ""); a remote source is pulled first.
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
        # The copy primitive raises on a missing source, and Starlark cannot
        # catch that: a row whose file is gone should degrade, not abort.
        source = attachment_filename(id, name)
        if not mochi.file.exists(source):
            return None
        size = mochi.file.copy(source, destination)
    if size == None:
        return None

    attachment_row_append(new, object, name, size, row.get("content_type", ""), "",
                          attachment_text(caption, attachment_text_maximum),
                          attachment_text(description, attachment_text_maximum),
                          mochi.time.now(), "")
    return attachment_map(attachment_row(new), mochi.app.url(), "")

# attachment_fetch(id, requester="") makes sure a remote attachment's bytes are
# in cache, returning whether they are available. Use this rather than
# attachment_data to warm the cache - that one reads the object into memory.
def attachment_fetch(id, requester=""):
    row = attachment_row(id)
    if not row:
        return False
    if not row.get("entity"):
        return True
    return attachment_pull(id, row, requester)

# attachment_entry(id, name, requester="") returns a mochi.archive.write entry
# naming this attachment's bytes, so an export streams them off disk. Pair with
# attachment_extract. A remote copy is referenced in cache, never adopted.
def attachment_entry(id, name, requester=""):
    row = attachment_row(id)
    if not row:
        return None
    if row.get("entity"):
        if not attachment_pull(id, row, requester):
            return None
        return {"name": name, "cache": attachment_cache_name(id)}
    return {"name": name, "file": attachment_filename(id, row["name"])}

# attachment_extract(archive, entry, object, name, ...) stores one archive entry
# as an attachment on object, streaming from the container without reading the
# bytes. Returns the response dict, or None if the entry is absent.
def attachment_extract(archive, entry, object, name, content_type="", caption="", description=""):
    # The name comes out of a user-supplied import archive, so it is canonical
    # here for the same reason it is on every other entry point - and because a
    # non-string would otherwise abort the whole import inside mochi.file.clean.
    name = attachment_name(name)
    id = mochi.uid()
    size = mochi.archive.extract(archive, entry, attachment_filename(id, name))
    if size == None:
        return None
    if not content_type:
        content_type = attachment_content_type(name)
    attachment_row_append(id, object, name, size, content_type, "",
                          attachment_text(caption, attachment_text_maximum),
                          attachment_text(description, attachment_text_maximum),
                          mochi.time.now(), "")
    return attachment_map(attachment_row(id), mochi.app.url(), "")

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
# original and variants with their pull bookkeeping, and an own image's
# rendered variants.
def attachment_forget(row):
    if row.get("entity"):
        for variant in ["", "thumbnail", "preview"]:
            mochi.cache.delete(attachment_cache_name(row["id"], variant))
            # A backoff marker left behind handed its verdict to any row
            # re-filed under this id inside the window, and a leftover
            # partial would resume a transfer the new row never started.
            mochi.cache.delete(attachment_backoff_name(row["id"], variant))
        mochi.cache.delete(attachment_partial_name(row["id"]))
        return
    # An own image's variants live in cache under a name derived from the
    # file's, mirroring core's variant naming. The test suite holds the
    # derivation equal to what mochi.image.variant returns, so a rename there
    # fails loudly.
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
# attachment's bytes or an image variant. THE CALLING ACTION IS THE GATE:
# authorize the requester against container before calling
# (check-attachment-access.py enforces a visible gate). The attachment must be
# bound to container, directly or via member(object).
def attachment_serve(a, id, container, variant="", member=None, adopt=False):
    row = attachment_row(id)
    if not row:
        a.error.label(404, "attachment.errors.not_found")
        return
    if not attachment_bound(row, container, member):
        a.error.label(404, "attachment.errors.not_found")
        return

    # Remote row: pull the requested representation into cache on demand,
    # falling back to the original when a variant cannot be produced. The
    # content type derives from the attachment's NAME on every branch, never
    # from the row's content_type column - for a remote row that column is the
    # peer's claim.
    kind = mochi.file.type(row["name"])
    if row.get("entity"):
        requester = a.user.identity.id if (a.user and a.user.identity) else container
        # Only the container's canonical holder adopts, taking the bytes in on
        # first serve; a subscriber pulls to cache instead. The adopt pull opens
        # as the container entity - that is what the uploader's responder knows.
        if adopt and attachment_adopt(id, container):
            row = attachment_row(id)
        else:
            # a.write.cache answers False on a miss, and the cache is evictable
            # at any moment - an eviction between the pull and the serve would
            # otherwise be an empty 200 with a cacheable ETag. Fall through to
            # the original, then to the error, exactly as the own-row branch
            # falls through from a variant that could not be rendered.
            want = variant if (variant and attachment_is_image(row["name"])) else ""
            if want and attachment_pull(id, row, requester, want):
                if a.write.cache(attachment_cache_name(id, want), content_type=kind):
                    return
            pulled = attachment_pull(id, row, requester, "")
            if pulled:
                if a.write.cache(attachment_cache_name(id, ""), content_type=kind):
                    return
                a.error.label(503, "attachment.errors.unavailable")
                return
            # Told apart by the pull's failure class: a source that answered
            # negatively means the bytes are gone (404), while one that could
            # not be reached says nothing about them (503, retryable).
            if pulled == None:
                a.error.label(503, "attachment.errors.unavailable")
            else:
                a.error.label(404, "attachment.errors.not_found")
            return

    # Own row: serve the original from file storage, or an image variant which
    # mochi.image.variant renders into cache on demand.
    if variant and attachment_is_image(row["name"]):
        name = mochi.image.variant(attachment_filename(id, row["name"]), variant)
        if name and a.write.cache(name, content_type=kind):
            return
    # a.write.file reads the route entity OWNER's storage, while the row above
    # came from mochi.db and the variant above from mochi.image.variant, both of
    # which read the CALLER's. Those differ whenever a non-owner serves an
    # attachment they uploaded themselves, whose bytes are in the uploader's
    # storage. The owner usually holds a copy too, from the push or the fan-out,
    # so ask for the caller's own storage only once the caller is shown to hold
    # the file, leaving the owner's copy as the fallback.
    file = attachment_filename(id, row["name"])
    a.write.file(file, storage=(a.user != None and mochi.file.age(file) != None))

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

# attachment_store(rows, entity, object) records remote attachment metadata from
# the app's own event handler; sender authorization is the handler's, this only
# writes rows. entity is the provenance of the bytes; object is required, since
# a row's own claim would let a peer file against any object in the database.
# Returns the list of ids accepted - len() for the count, and the only safe
# input to anything that then acts on the sender's ids.
def attachment_store(rows, entity, object):
    # Both sequence shapes are legitimate: a local caller builds a list, core
    # decodes every wire array to a tuple. A peer sending a scalar would abort
    # the domain handler on iteration itself, losing the comment, not just rows.
    if type(rows) not in ["list", "tuple"]:
        return []
    if type(object) != "string" or not object:
        return []
    # The entity is the rows' provenance and the source every later pull
    # dials; without one the rows landed as OWN rows (entity ''), bytes-less
    # and served from a file that does not exist. An event with no from
    # header reaches attachment_accept with exactly that.
    if type(entity) != "string" or not entity:
        return []
    if len(rows) > attachment_store_maximum:
        mochi.log.debug("attachment_store truncating %d rows to %d", len(rows), attachment_store_maximum)
        rows = rows[:attachment_store_maximum]
    # attachment_store_maximum bounds one call; this bounds the object across
    # all of them, so a peer repeating create and edit cannot keep adding a
    # batch every time. Counted once: object is the same for every row.
    filed = mochi.db.row("select count(*) as total from attachments where object=?", object)["total"]
    accepted = []
    for attachment in rows:
        if type(attachment) != "dict":
            continue
        id = attachment.get("id")
        if not attachment_identifier(id):
            continue
        # The object is the CALLER's, never the row's: taking it from the row
        # would let a peer file rows against any object id in the database.
        if attachment_conflict(id, object):
            continue

        # A peer's name is a claim like the rest of its row: the same canonical
        # form the local paths apply, so nothing peer-shaped reaches the disk
        # name or a Content-Disposition header.
        name = attachment_name(attachment_text(attachment.get("name", ""), attachment_name_maximum))
        size = attachment_number(attachment.get("size", 0))
        content_type = attachment_text(attachment.get("content_type", ""), attachment_name_maximum)
        caption = attachment_text(attachment.get("caption", ""), attachment_text_maximum)
        description = attachment_text(attachment.get("description", ""), attachment_text_maximum)
        # Zero is what attachment_number reduces anything unusable to, and
        # doubles as the sentinel for "no usable position" - such a row appends
        # rather than landing below the floor every ordering query assumes.
        rank = attachment_number(attachment.get("rank", 0))
        if rank > attachment_position_maximum:
            rank = 0

        # An id already held under this object is an annotation update: only
        # caption, description and rank are the sender's to restate. name in
        # particular is the address - the bytes live at attachment_filename(id,
        # name), so changing it moves the path without moving the file.
        existing = attachment_row(id)
        if existing:
            # A restatement may only annotate a row whose provenance matches the
            # sender: a peer quoting an id could otherwise rewrite our caption,
            # description and order. Adoption sets entity '' while keeping the
            # creator, so the uploader keeps annotating a row whose bytes the
            # owner has since taken in - without that second arm, every caption
            # edit made after an adoption was silently discarded.
            if existing.get("entity", "") != entity:
                if existing.get("entity", "") or existing.get("creator", "") != entity:
                    continue
            attachment_annotate(existing, caption, description, rank)
            accepted.append(id)
            continue

        if filed >= attachment_object_maximum:
            mochi.log.debug("attachment_store refusing %s: object %s holds %d rows", id, object, filed)
            continue

        # A row without a usable rank appends, choosing the position inside
        # the insert for the same reason attachment_row_append does: two
        # events landing rows on one object race on any read-then-write.
        mochi.db.execute(
            """insert into attachments ( id, object, entity, name, size, content_type, creator, caption, description, rank, created )
               values ( ?, ?, ?, ?, ?, ?, ?, ?, ?, coalesce( nullif( ?, 0 ), ( select coalesce( max( rank ), 0 ) + 1 from attachments where object=? ) ), ? )""",
            id, object, entity, name, size, content_type,
            attachment_text(attachment.get("creator", ""), attachment_name_maximum),
            caption, description, rank, object,
            attachment_number(attachment.get("created", 0)) or mochi.time.now())
        filed = filed + 1
        accepted.append(id)
    return accepted

# The annotation half of attachment_store: caption, description and rank are
# the only fields a restating sender owns. A rank change shifts its siblings,
# for the reason attachment_move and attachment_insert both do - without it two
# rows on one object end up sharing a rank and the order is whichever statement
# landed last.
def attachment_annotate(existing, caption, description, rank):
    if not rank or rank == existing.get("rank", 0):
        mochi.db.execute(
            "update attachments set caption=?, description=? where id=?",
            caption, description, existing["id"])
        return
    count = mochi.db.row("select count(*) as total from attachments where object=?", existing["object"])["total"]
    new = rank if rank <= count else count
    old = existing.get("rank", 0)
    handle = mochi.db.transaction()
    if new < old:
        handle.execute("update attachments set rank = rank + 1 where object=? and rank >= ? and rank < ?", existing["object"], new, old)
    else:
        handle.execute("update attachments set rank = rank - 1 where object=? and rank > ? and rank <= ?", existing["object"], old, new)
    handle.execute("update attachments set caption=?, description=?, rank=? where id=?", caption, description, new, existing["id"])
    handle.commit()

# A peer's row is data, not a promise about its shape: the helpers below reduce
# each field to the type the rest of the library assumes. A wrong type is not
# inert - a name that is a number aborts the handler at name.lower().

# attachment_identifier reports whether id is a well formed attachment id: 32
# lowercase hex characters, which is what mochi.uid() mints and what the sweep's
# attachment_hex admits. Anything else can never address bytes.
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
    # cannot be bound as a parameter at all. This is the general bound; ranks
    # are clamped tighter where they are read.
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

# Where a pull accumulates an incomplete transfer. Its own prefix, never the
# served name: cache.append writes straight into the entry so interrupted
# bytes survive, and a partial must not be servable until renamed whole.
def attachment_partial_name(id):
    return "partial/" + id

# attachment_pull(id, row, requester, variant="") ensures a remote attachment's
# bytes are in cache, requesting them from the row's provenance entity. True
# when present; None when the source could not be reached, False when it
# answered and the bytes are not to be had. Failures back off, and the marker
# records the class.
def attachment_pull(id, row, requester, variant=""):
    name = attachment_cache_name(id, variant)
    if mochi.cache.path(name):
        return True
    marker = attachment_backoff_name(id, variant)
    age = mochi.cache.age(marker)
    if age != None and age < attachment_backoff_seconds:
        # Still within the backoff window; not a tombstone. Answer with the
        # class of the failure being backed off ("unreachable" means
        # transport; anything else, including a marker from before classes
        # existed, means the source answered).
        if str(mochi.cache.read(marker) or "") == "unreachable":
            return None
        return False

    entity = row.get("entity", "")
    if not entity or not requester:
        mochi.log.debug("attachment_pull %s: no entity (%s) or requester (%s)", id, entity, requester)
        return False
    # requester is the local entity opening the stream; `to` is the source from
    # app state, never a field a response claims. The frame routes by the app's
    # declared SERVICE, which is not always its URL prefix (comptroller:
    # market).
    services = mochi.app.services()
    # Resume: an earlier attempt's surviving bytes set the offset this request
    # asks the source to continue from. Originals only - a variant declares no
    # size, so a partial of one could never be judged complete - and only on a
    # core carrying the primitives; anywhere else the path below is exactly
    # the whole-transfer one.
    declared = int(row.get("size", 0))
    partial = attachment_partial_name(id)
    offset = 0
    if not variant and declared > 0:
        offset = mochi.cache.size(partial) or 0
        if offset >= declared:
            # A partial at or past the declared size cannot be right - the
            # exactness check would have promoted a complete one.
            mochi.cache.delete(partial)
            offset = 0
    request = {"id": id, "object": row["object"], "variant": variant}
    if offset:
        request["offset"] = offset
    stream = mochi.stream(
        {"from": requester, "to": entity, "service": services[0] if services else mochi.app.url(), "event": "attachment/fetch"},
        request)
    outcome = False
    if not stream:
        mochi.log.debug("attachment_pull %s: stream open to %s failed", id, entity)
        outcome = None
    if stream:
        response = stream.read()
        if not response:
            # The stream opened and then died before an answer arrived - the
            # transport failed, not the source's verdict.
            mochi.log.debug("attachment_pull %s: no response", id)
            outcome = None
        elif response.get("status") != "200":
            mochi.log.debug("attachment_pull %s: response %s", id, str(response))
        else:
            # The source continues from our offset only when it says so: a
            # responder from before resume ignores the field and serves the
            # whole file, so an unechoed offset means start over - discard the
            # partial rather than appending a second copy of the front.
            if offset and attachment_number(response.get("offset", 0)) != offset:
                mochi.log.debug("attachment_pull %s: source restarted the transfer", id)
                mochi.cache.delete(partial)
                offset = 0
            # Bound the transfer to the size the row declares, so a peer cannot
            # push gigabytes through the disk before the size check runs. Core
            # cuts one byte past the bound, so an overrun fails the check below.
            if not variant and declared > 0:
                # Through the partial, so bytes survive an interruption and
                # the next attempt continues instead of starting over.
                total = mochi.cache.append(partial, stream, offset, maximum=declared - offset)
                if total == None:
                    # The primitive answers None when the transfer could not
                    # run - the partial is held by another transfer, its size
                    # moved under us, or the write failed - rather than
                    # raising, which aborted the handler that was serving.
                    # The transport class: whatever the partial holds stays
                    # for the retry.
                    outcome = None
                elif attachment_complete(total, declared, variant):
                    mochi.cache.rename(partial, name)
                    outcome = True
                elif total > declared:
                    # A padded transfer poisons the partial; nothing in it can
                    # be trusted to be our bytes.
                    mochi.cache.delete(partial)
                    outcome = None
                else:
                    # Short: the wire broke. The partial keeps what arrived,
                    # and the backoff'd retry resumes from it - the transport
                    # class, not a verdict.
                    outcome = None
            else:
                written = mochi.cache.write(name, stream, maximum=attachment_transfer(declared, variant))
                if written != None and attachment_complete(written, declared, variant):
                    outcome = True
                else:
                    # A truncated or padded transfer, or a write the cache
                    # could not commit (None): the source holds the bytes and
                    # the wire or the disk failed to carry them, so the next
                    # retry may succeed - the transport class, not a verdict.
                    mochi.cache.delete(name)
                    outcome = None
    if outcome != True:
        # Record the failure time and class; attachment_backoff_seconds later
        # the next access retries. cache.age reads the write time without
        # touching it.
        mochi.cache.write(marker, "unreachable" if outcome == None else "refused")
    return outcome

# attachment_complete judges a pulled body against the size the row declares.
# Originals only - a variant's size is not known ahead of time. Both directions
# matter: a short body is a truncated transfer, and accepting it caches a prefix
# that is then served as whole and never retried.
# attachment_transfer(declared, variant) -> int: the ceiling one pull may write.
# Every transfer is bounded, and maximum=0 is core's UNBOUNDED sentinel (its
# 10 GB object maximum) rather than "nothing" - so neither a variant, which
# declares no size at all, nor a row declaring zero may be handed through raw:
# the first let a thumbnail request stream gigabytes, the second let any peer do
# it by declaring nothing. A zero declaration is held to one byte, so core cuts
# at it and the completeness check sees the overrun.
def attachment_transfer(declared, variant=""):
    if variant:
        return attachment_variant_maximum
    return declared if declared > 0 else 1

def attachment_complete(written, declared, variant=""):
    if variant:
        # A variant declares no size, so exactness is not available - but the
        # ceiling is: core cuts one byte past the bound, so a body that reaches
        # it is an overrun and must not be kept and served as the thumbnail.
        return written < attachment_variant_maximum
    # Zero is a legitimate declaration - an empty file is a real attachment - so
    # it is held to its word rather than accepting any size.
    if declared == 0:
        return written == 0
    if declared < 0:
        return False
    # Exact in both directions: the source streams a file whose size the row
    # records, so there is no honest way for the two to differ. The transfer
    # bound cuts a padded body to declared+1 so it lands here as an overrun.
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

    # A resuming requester names the offset its surviving partial ends at.
    # Honoured only when it can be honoured exactly - originals, a sane range,
    # a core whose file writer takes an offset - and CONFIRMED by echoing it
    # in the answer: the requester appends only on that echo, so a responder
    # that cannot resume (this branch untaken) serves the whole file and the
    # requester starts over cleanly. Bounds-checked against the row's size,
    # which for a local row is the file's.
    # The status goes out before the body, so an own row whose file is missing
    # (the orphan attachment_copy guards against) would
    # answer 200 with nothing behind it - which attachment_pull reads as a
    # transport failure and retries every backoff forever instead of learning
    # the bytes are gone.
    filename = attachment_filename(id, row["name"])
    if mochi.file.age(filename) == None:
        e.write({"status": "404"})
        return
    offset = attachment_number(e.content("offset", 0))
    if offset and not variant and offset < attachment_number(row.get("size", 0)):
        e.write({"status": "200", "offset": offset})
        e.write.file(filename, offset=offset)
        return
    e.write({"status": "200"})
    e.write.file(filename)

# attachment_push(container, object, stored, requester) streams locally saved
# attachments to container's owner, one attachment/push stream each: metadata,
# bytes, ack. The owner is canonical, so a row only exists downstream of the
# bytes it describes; the first failure stops the batch and the caller unwinds.
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
        # Two phases, strictly alternating: the owner answers on the metadata
        # before any byte moves, so whichever side writes, the other reads. A
        # 200 at the go-ahead is the retry case and the bytes stay home.
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
# stream: validate the claims, stream the bytes, write the own row, ack.
# AUTHORIZATION IS THE CALLING HANDLER'S, as for the HTTP upload action.
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
    declared = attachment_number(e.content("size", 0))
    # Go-ahead: the metadata passed judgement, so invite the bytes. The pusher
    # reads this before writing them (see attachment_push on why the phases
    # must alternate).
    e.write({"status": "100"})
    # The declaration bounds the transfer and is held to exactly, as the pull
    # path holds its row's size: without it a pusher wrote the owner's whole
    # remaining quota before any check ran, and a transfer core cut short at
    # that quota was recorded at its truncated length and acked 200 - every
    # subscriber then pulled a prefix that looked complete, because the row
    # agreed with it.
    attachment = attachment_receive(object, name, e, content_type, id,
                                    creator=creator, caption=caption, description=description,
                                    declared=declared)
    if not attachment:
        e.write({"status": "400"})
        return None
    e.write({"status": "200"})
    return attachment

# attachment_accept(rows, sender, object, requester="") stores the rows as
# attachment_store does, then takes each one's bytes in from the just-online
# sender. A failed pull leaves that row remote; the submission is never rejected
# over its attachments.
def attachment_accept(rows, sender, object, requester=""):
    # Only the ids attachment_store ACCEPTED: re-checking the shape would adopt
    # ids it skipped for a conflict or a provenance mismatch, and adoption pulls
    # from that row's entity and rewrites it to own - charging this user's quota
    # for a row the sender has nothing to do with. Each adopt is a synchronous
    # P2P stream, so the batch is bounded well below the store's row cap.
    accepted = attachment_store(rows, sender, object)
    for id in accepted[:attachment_adopt_maximum]:
        attachment_adopt(id, requester)
    if len(accepted) > attachment_adopt_maximum:
        mochi.log.debug("attachment_accept adopted %d of %d rows", attachment_adopt_maximum, len(accepted))
    return len(accepted)

# attachment_adopt(id, requester="") turns a remote-provenance row into an own
# one: pull into cache, copy into file storage under the name every other host
# knows, flip the row. The size is re-recorded from the copy, not the peer's
# claim. Idempotent.
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

# Removes stored files no row references - a create writes the file before the
# row, so an abort leaves an orphan. age guards an upload still in flight, whose
# file is indistinguishable from an orphan until its row lands; a handler cannot
# outlive the Starlark time limit. Skipped where mochi.file.age is unavailable.
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

# attachment_sweep_due(age=3600) runs the orphan sweep when the last one is
# older than attachment_sweep_seconds, or none has run, and reports whether it
# ran. The marker is written first, so a sweep that aborts is not retried on
# every upload. age is the sweep's own settling period, passed through.
def attachment_sweep_due(age=3600):
    since = mochi.cache.age(attachment_sweep_marker)
    if since != None and since < attachment_sweep_seconds:
        return False
    mochi.cache.write(attachment_sweep_marker, "")
    attachment_sweep(age)
    return True

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
# store: one JSON list per (user, app) at the root of the app's file storage.
# Each entry holds an attachment row's columns plus "file", the stored filename
# of an own row ("" for a remote one).
attachment_export_file = "attachments.json"

# attachment_export() returns the rows core's store held for this user and app,
# from the export file core wrote before dropping its own store. Absence means
# no rows - core exported every store that had any before serving a request. An
# export that exists and cannot be read aborts the migration - damaged, not
# empty.
def attachment_export():
    if not mochi.file.exists(attachment_export_file):
        return []
    rows = json.decode(str(mochi.file.read(attachment_export_file) or ""), None)
    if type(rows) != "list":
        mochi.db.abort("attachment export unreadable")
        return None
    return rows

# attachment_migrate() copies attachment rows out of core's store into this
# app's table, once, from a database_upgrade step. Ids are preserved verbatim
# (URLs and remote references depend on them); an own row's file moves to the
# name this library addresses when core kept it under another.
def attachment_migrate():
    rows = attachment_export()
    if rows == None:
        return
    for attachment in rows:
        # A non-dict element aborts at .get, and an id carrying a path separator
        # makes a filename mochi.file refuses - so every later delete on that row
        # aborts too. The schema version bumps even on a failed migration, so an
        # abort here is permanent and needs the next version number to repair.
        if type(attachment) != "dict":
            continue
        id = attachment.get("id")
        if not attachment_identifier(id) or attachment_exists(id):
            continue
        name = attachment_name(attachment.get("name", ""))
        entity = attachment_text(attachment.get("entity", ""), attachment_name_maximum)
        if not entity:
            attachment_relocate(id, name, attachment.get("file", ""))
        attachment_row_write(
            id, attachment.get("object", ""), name, attachment.get("size", 0),
            attachment.get("content_type", ""), attachment.get("creator", ""), attachment.get("caption", ""),
            attachment.get("description", ""), attachment.get("rank", 0),
            attachment.get("created", 0) or mochi.time.now(), entity)

# attachment_relocate(id, name, stored) moves a migrated own row's bytes from the
# name core's store kept them under - "file" in the export, recorded verbatim -
# to the name this library addresses, when the two differ. The library derives
# the address from the row's name through mochi.file.clean and core's store did
# not, so a name that rule rewrites (over the component limit, or carrying a
# character it replaces) left the row pointing at nothing while its bytes sat
# under the old name. A stored name the path validator refuses cannot be moved
# from Starlark at all - mochi.file raises on it - and is left for a repair by
# hand rather than aborting the migration, which would be permanent.
def attachment_relocate(id, name, stored):
    if type(stored) != "string" or not stored:
        return
    canonical = attachment_filename(id, name)
    if stored == canonical:
        return
    if not mochi.text.valid(stored, "filepath"):
        mochi.log.debug("attachment_migrate %s: stored name is not a valid path, bytes left under it", id)
        return
    if not mochi.file.exists(stored) or mochi.file.exists(canonical):
        return
    mochi.file.move(stored, canonical)
