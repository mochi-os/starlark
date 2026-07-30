# Mochi shared Starlark libraries

Reusable Starlark modules vendored into Mochi apps. Each app symlinks the module
it needs into `apps/<app>/lib/` (gitignored) and lists it first in `app.json`
`execute`; release zips materialise the symlink into a real file, so published
apps stay self-contained and pin the version they shipped with.

## Modules

- `attachments.star` — app-owned file attachments (storage, serving, P2P
  byte-pull, image variants, migration off core's built-in attachment store).
  See `claude/plans/starlark-libraries.md` in the umbrella.
