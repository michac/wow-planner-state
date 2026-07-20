# PlannerState addon — working notes

A small WoW addon that dumps reset-state to SavedVariables for the
[wow](https://github.com/michac/wow) session planner. The addon files live in
`PlannerState/` (`.toc` + `.lua`); everything else here is repo scaffolding.

## Deploying a change (IMPORTANT — always cut a GitHub release)

This addon is installed/updated by **ghaddons**, which resolves each repo's
**latest GitHub release** (release `.zip` asset → release tagged source), and
only falls back to the default-branch HEAD when *no releases exist*. So a plain
`git push` is **not** a clean deploy — always publish a release so the addon
manager sees a real, named version instead of a `main@<sha>` snapshot.

Standard flow for any user-facing change:

1. Edit the source under `PlannerState/`.
2. Bump `## Version:` in `PlannerState/PlannerState.toc` (semver).
3. If the dumped table shape changed, bump `schema` in `PlannerState.lua` — the
   planner keys on it.
4. Syntax-check (no system lua is installed):
   ```bash
   uv run --with luaparser python -c \
     "from luaparser import ast; ast.parse(open('PlannerState/PlannerState.lua').read()); print('OK')"
   ```
5. Commit and push to `main`.
6. **Cut the release** — this is the step that actually ships it to `ghaddons`:
   ```bash
   gh release create vX.Y.Z -R michac/wow-planner-state \
     --title "vX.Y.Z — <summary>" --notes "<what changed>"
   ```
   (`gh` can create releases non-interactively; the tag should match the `.toc`
   Version, prefixed with `v`.)
7. Deploy — pulls the release into `Interface/AddOns/`. Runnable from any
   directory (ghaddons keeps its config next to its own package, not in the cwd),
   from WSL or from Windows `python`:
   ```bash
   PYTHONPATH=~/code/fun/wow/addon-manager python3 -m ghaddons.cli update michac/wow-planner-state
   ```
   Confirm with `... list` (should read `ok` at the new version), then in-game
   `/ps` + `/reload` to write the new dump.

Keep the tag, the `.toc` Version, and the release title in sync.

## Conventions

- Every game-API call goes through `safe()` (pcall wrapper) so a missing/changed
  API omits one field instead of erroring the whole dump.
- Quest/item IDs (`ns.WEEKLY_QUESTS`, `ns.ITEMS`) are patch-specific — only add
  IDs verified against the live build; a wrong ID false-reports "done", which is
  worse than a gap.
