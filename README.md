# MotoJoust

A Roblox **bike combat sandbox** — free-roam motorcycles with combat.

Code is managed with [Rojo](https://rojo.space) (live-sync into Studio),
dependencies with [Wally](https://wally.run), and the architecture uses
[Knit](https://sleitnick.github.io/Knit/). The world/arena lives in
`MotoJoust.rbxl`, edited in Roblox Studio.

> **Working with Claude Code here?** Read [`CLAUDE.md`](./CLAUDE.md) first —
> it defines the hard boundary between code (Rojo/`src/`) and world (Studio).

## First-time setup

```bash
aftman install     # rojo, wally, stylua, selene (versions pinned in aftman.toml)
wally install      # downloads Knit etc. into Packages/
```

## Develop

1. Open `MotoJoust.rbxl` in Roblox Studio.
2. Run the Rojo server: `rojo serve`
3. In Studio, use the Rojo plugin → **Connect**.
4. Edit files under `src/` — changes live-sync into the running place.

## Project layout

| Path | Maps to | Purpose |
|---|---|---|
| `src/shared` | `ReplicatedStorage.Shared` | Shared modules (`Config.luau` = all tuning) |
| `src/server` | `ServerScriptService.Server` | Knit services (server authority) |
| `src/client` | `StarterPlayer.StarterPlayerScripts.Client` | Knit controllers (local player) |
| `MotoJoust.rbxl` | the place itself | Arena/world/assets — **edited in Studio only** |

## Quality checks

```bash
stylua src     # format
selene src     # lint
rojo build default.project.json -o build-check.rbxl   # structure/parse check (throwaway output)
```
