# Mochi shared Starlark libraries

Reusable Starlark modules vendored into Mochi apps. Each app symlinks the module
it needs into `apps/<app>/lib/` (gitignored) and lists it first in `app.json`
`execute`; release zips materialise the symlink into a real file, so published
apps stay self-contained and pin the version they shipped with.

## Modules

- `attachments.star` — app-owned file attachments (storage, serving, P2P
  byte-pull, image variants, migration off core's built-in attachment store).
  See `claude/plans/starlark-libraries.md` in the umbrella.

## Checks

`make check` runs what a standalone checkout can verify: syntax (Starlark is
syntactically a Python subset and this file stays inside the overlap), no name
defined twice, and no module-level constant used above its definition. The
behavioural suite needs a running server and lives with the platform: the
`test` app drives every function, and `claude/scripts/p2p-test.py` drives the
P2P paths end to end. Run both there before shipping a library change.
