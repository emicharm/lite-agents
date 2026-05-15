# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build

There is no test suite, lint config, or package manager — the project is a small C host plus Lua sources that are loaded at runtime.

- Linux/macOS: `./build.sh` → produces `./lite`
- Windows (cross-compile from Linux via MinGW): `./build.sh windows` → produces `lite.exe` and a `res.res` resource
- Windows (native, MinGW): `build.bat`
- Release bundle (both targets + zip with SDL2.dll + `data/`): `./build_release.sh`

Both build scripts compile every `*.c` under `src/` (including `src/lib/lua52/` and `src/lib/stb/`), so new C files in those trees are picked up automatically — no Makefile to update. The only build-time deps are a C11 compiler and `libSDL2` (`-lSDL2 -lm`); Lua 5.2 and stb are vendored under `src/lib/`. On Windows the script also runs `windres res.rc`.

Lua-only changes do **not** require a rebuild — just relaunch `./lite`.

Run with `./lite [path]`. A directory argument becomes the project root; file arguments are opened as docs. `LITE_SCALE=<n>` env var overrides the autodetected HiDPI scale (see `src/main.c:18` `get_scale`).

## Architecture

lite is a **thin C host that runs a Lua editor**. Almost everything user-visible — views, commands, keymap, syntax, plugins — is Lua. The C side just exposes SDL2-backed window/event/IO/rendering primitives.

### C ↔ Lua boundary

- `src/main.c` boots SDL, creates the window, opens a `lua_State`, registers the native modules, and `dostring`s a small bootstrap that sets `package.path` to `EXEDIR/data/?.lua` and calls `core.init()` / `core.run()`. Globals it injects: `ARGS`, `VERSION`, `PLATFORM`, `SCALE`, `EXEFILE` (Lua then derives `EXEDIR`, `PATHSEP`).
- `src/api/api.c` registers two native modules into Lua:
  - **`system`** (`src/api/system.c`) — event polling (`system.poll_event` drives the whole editor loop), window control, file/dir ops, dialogs, clipboard, `chdir`, `exec`, `sleep`, `get_time`, fuzzy match. Pulls in `get_scale()` from `main.c` to scale mouse/drop coordinates on HiDPI.
  - **`renderer`** (`src/api/renderer.c` + `src/api/renderer_font.c`) — font loading, text/rect drawing, clip rect. Lua never talks to SDL directly; it talks to `renderer.*`, which goes through `rencache` (see below).
- `src/renderer.c` / `renderer.h` is the SDL surface-based pixel renderer (stb_truetype for fonts, vendored at `src/lib/stb/`).
- `src/rencache.c` sits between the Lua `renderer` module and `renderer.c`. It batches draw commands per frame and **only repaints rectangles that changed since last frame** — this is why the editor idles at ~0% CPU. Any change to draw semantics has to keep the cache's per-cell hashing intact, or you'll get stale pixels / over-redraw.

### Lua side (`data/`)

`data/core/init.lua` is the entry point. The core layout:

- `core.run()` is the main loop: poll events → update → maybe redraw → run cooperative threads → sleep to hit `config.fps`. Calls `system.wait_event` when idle and unfocused, which is what lets the editor sleep until input.
- **Threads are Lua coroutines**, not OS threads. `core.add_thread(fn)` schedules a coroutine; yielding a number sleeps that many seconds. Used for things like the background project file scan and project-wide search. They get a time budget per frame (`1/fps - 0.004`) and yield when it's exhausted.
- **Views** (`core.view` base, `RootView`, `DocView`, `StatusView`, `CommandView`, `LogView`) compose a tree under `core.root_view`. Splits and tabs are managed by `Node` inside `rootview.lua`.
- **Docs** (`core.doc`, under `data/core/doc/`) are the text buffers. Tokenization is in `core.tokenizer` driven by patterns registered with `core.syntax` (one file per language under `data/plugins/language_*.lua`).
- **Commands** (`core.command`) are `namespace:action` strings with a predicate + function. `command.perform` runs them; `core.keymap` binds keystrokes to one-or-more commands and walks them until a predicate passes.
- **Plugins** are just Lua modules under `data/plugins/`. `core.load_plugins()` `require`s every `*.lua` in that dir at startup, after which the user module (`data/user/init.lua`) loads, then an optional `.lite_project.lua` from the project root. Errors in any of these surface by auto-opening the log view.

### Where to add things

- New language highlighting → a `data/plugins/language_<name>.lua` registering patterns/symbols with `core.syntax`.
- New editor feature that could be a plugin → put it under `data/plugins/`, not the core. The upstream policy (README) is to reject core PRs for things that can live as plugins.
- New native capability → add a function to `src/api/system.c` (or a new `luaopen_*` registered in `src/api/api.c`), then call it from Lua. The build script auto-globs, so just dropping the `.c` in is enough.
- HiDPI: anything that converts between SDL pixel coordinates and Lua-space coordinates must respect `get_scale()` (see how `SDL_DROPFILE` and `SDL_MOUSE*` events are scaled in `src/api/system.c`).

## Core writing principles

These hold for any change in this repo:

- **Plugins over core.** Default to a new file under `data/plugins/`. Monkey-patch core classes (`RootView`, `StatusView`, `View`, `keymap`) by saving the previous method and wrapping it — this is the standard extension mechanism here. Edit `data/core/*` only when the change is structural (rendering pipeline, layout math, event loop) or when the surface you'd need to patch is a local-to-the-module class (e.g. `Node` inside `rootview.lua`, which is not exported).
- **Config is the source of truth for tunables.** Add knobs to `data/core/config.lua` in unscaled pixels (`config.gap_size`, `config.panel_radius`, …) and have a plugin mirror them into `style.*` each `update()`. Don't bake numbers into `style.lua` if a user might want to tune them — `style.lua` runs once at startup, so values set there can't be overridden live from `data/user/init.lua`.
- **Animation rates are 60-fps-relative.** `View:move_towards` rescales its `rate` argument by `(60 / config.fps)`. Pass rates as if `config.fps == 60` and let the function compensate — never tune animations against the current fps.
- **Platform conventions go in plugins.** macOS Cmd→Ctrl translation, Windows-specific quirks, etc. live in `data/plugins/*` and gate themselves with `if PLATFORM ~= "Mac OS X" then return end`. Don't pollute `keymap.lua` or other core with platform branches.
- **Themes are Lua, not JSON.** Color themes go in `data/user/colors/<name>.lua` and overwrite `style.*` fields. Port external palettes (VS Code JSONs, etc.) by mapping their semantic keys to lite's: `editor.background → style.background`, `editor.lineHighlightBackground → style.line_highlight`, syntax token foregrounds to the ten `style.syntax[*]` keys.
- **Lua-only changes don't need a rebuild.** Restart `./lite` — no `build.sh` run necessary. Only rebuild when you touched `src/`.
- **HiDPI is the renderer's responsibility, not the caller's.** Coordinates coming out of `src/api/system.c` (mouse, drops) are already pre-scaled by `get_scale()`. Lua code multiplies sizes by the global `SCALE` (e.g. `config.gap_size * SCALE`). Don't double-scale.
- **Don't break the dirty-rect cache.** Any new renderer primitive must go through `rencache_*` (not call `ren_*` directly from Lua bindings) so per-cell hashing sees it and dirty rects are computed correctly. New `Command` fields must be hashable as part of `cmd->size`.

## Task tracking

- Simple tasks are written in todo.txt
- When task is done you write at the start of line "x" to mark its complition


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:7510c1e2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
