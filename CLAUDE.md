# CLAUDE.md — MotoJoust

Guidance for Claude Code working in this repository. Read this fully before
making changes.

## What this is

**MotoJoust** is a Roblox **bike combat sandbox**: players free-roam on
motorcycles and fight (ram damage now, weapons later). No strict rounds.

## Current scope

- Bikes spawn, move, and ram each other for damage.
- **No** weapons, rounds, matchmaking, datastores, or UI beyond the placeholder HUD.
- "later" in this doc means *not now*. **Do not pre-scaffold systems we haven't
  asked for** — implement exactly what the task requests, leave clear extension
  points (TODOs), and stop. Ask before adding a new subsystem.

## ⚠️ The golden rule: code vs. world

This repo has two completely separate domains. Keep them separate.

| Domain | Lives in | Owner | Claude may edit? |
|---|---|---|---|
| **Code** (gameplay logic, UI logic) | `src/**/*.luau` | Claude | ✅ Yes |
| **World** (arena, parts, models, Lighting, Terrain) | `MotoJoust.rbxl` | The user, in Roblox Studio | ❌ **Never** |

`MotoJoust.rbxl` is a **binary Roblox place file**. Do not read it, parse it,
`rojo build` over it, or try to "edit the arena" — you can't, and attempting it
risks corrupting the user's world. If a task needs new geometry/assets, **stop
and describe what the user should build in Studio**, then write the code that
drives it (referencing instances by name/attribute).

Rojo is deliberately scoped to code only (`default.project.json` has no
`Workspace`), so `rojo serve` will never overwrite Studio-built geometry.

## Architecture (Knit)

Knit (`sleitnick/knit`, via Wally) provides the service/controller pattern.

```
src/
  shared/                 -> ReplicatedStorage.Shared   (client + server)
    Config.luau           -- ALL tuning/balance constants. No magic numbers elsewhere.
  server/                 -> ServerScriptService.Server
    init.server.luau      -- bootstrap: loads Services/, starts Knit
    Services/             -- one file = one Knit service (server authority)
      BikeService.luau    -- spawn/own/despawn bikes
      CombatService.luau  -- all damage resolution
      PlayerDataService.luau -- in-memory profiles (kills/deaths)
  client/                 -> StarterPlayer.StarterPlayerScripts.Client
    init.client.luau      -- bootstrap: loads Controllers/, starts Knit
    Controllers/          -- one file = one Knit controller (local player)
      BikeController.luau
      InputController.luau -- all input binding lives here, nowhere else
      HudController.luau
```

Wally dependencies install into `Packages/` (shared), `ServerPackages/`
(server-only), `DevPackages/` (dev/test). These are git-ignored and required
via `ReplicatedStorage.Packages.<Name>`.

### Adding a service or controller

Drop a new `*.luau` file in `Services/` or `Controllers/`. The bootstrap
auto-loads it — no registration needed. Follow the existing file as a template:
`Knit.CreateService`/`Knit.CreateController`, expose cross-system API as
methods, expose client-callable API under `Client`.

`KnitInit` runs first across all services (set up state, no cross-service
calls yet); `KnitStart` runs after every `KnitInit` (safe to call other
services, connect signals, start heartbeats/loops). **Wiring goes in
`KnitStart`, not `KnitInit`.**

### Conventions

- Every file starts with `--!strict` and a short header comment explaining its
  responsibility.
- Server is authoritative. Clients send *intent*, never results: e.g. the
  client sends "I rammed player X" via a Knit method/RemoteEvent; the server
  validates distance + relative velocity and resolves damage. **All damage is
  computed in `CombatService`** — nowhere else.
- Tuning values go in `shared/Config.luau` only.
- Format with StyLua and lint with Selene before finishing (see verify loop).
- Tabs for indentation, 120 col width (enforced by `stylua.toml`).

## Dev workflow

The user runs Studio + the Rojo plugin. Their loop:
`wally install` → open `MotoJoust.rbxl` in Studio → `rojo serve` → Connect in
the Rojo plugin → code changes in `src/` live-sync into the running place.

Claude does not run Studio. Claude edits `src/`, then verifies headlessly.

## Verify loop (run after code changes)

```bash
stylua src                                  # format
selene src                                  # lint
rojo build default.project.json -o build-check.rbxl   # compile/structure check
```

`build-check.rbxl` is a throwaway (git-ignored). **Never** build to
`MotoJoust.rbxl`. A successful `rojo build` confirms the project tree and all
`*.luau` parse; it does not run the game (that needs Studio).

No automated test suite yet (no `tests/`, no TestEZ). Verification is: Selene +
`rojo build` for lint/parse, play-testing in Studio for behavior. Don't add a
test framework unless asked — if pure logic in `shared/` later needs it, raise
it first.

Type-checking is `--!strict` + `.luaurc` — surfaced by luau-lsp/Studio, not by
the headless tools above. Regenerate the LSP sourcemap when files move:
`rojo sourcemap default.project.json -o sourcemap.json`.

## Setup commands

```bash
aftman install     # installs rojo, wally, stylua, selene (pinned in aftman.toml)
wally install      # populates Packages/ from wally.toml (run after edits to it)
```

## Gotchas

- `Packages/` is empty until `wally install` runs; `require` paths to Knit will
  look unresolved in an editor until then. That's expected, not a bug.
- Don't add geometry expectations without telling the user what to build in
  Studio — code can reference it, code cannot create the arena.
- `wally.lock` IS committed (reproducible installs). `Packages/` contents are not.
- Recent commits ("Add arena") are Studio world edits saved into the `.rbxl`;
  that's the user's lane, not Claude's.
