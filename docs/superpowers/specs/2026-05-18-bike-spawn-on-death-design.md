# Design: Player-Bound Bike — Death → Ragdoll → Respawn Loop

- **Date:** 2026-05-18
- **Status:** Approved (design); pending spec review
- **Topic:** bike-spawn-on-death
- **Architecture decision:** Approach 1 — signal-driven, `BikeService` owns the lifecycle state machine.

## Summary

The player is permanently bound to a bike (a real model with a `VehicleSeat`,
built in Studio) and cannot walk independently. The bike's `Health` attribute is
the player's life. When `Health <= 0` the player and bike detach and both become
ragdolls — a flopped player "corpse" and a limp, tumbling bike. The wreckage
lingers for `Config.Bike.RespawnSeconds` (3s), then is cleaned up and the player
respawns at a `SpawnLocation`, already seated and bound to a fresh bike.

## Goals

- Player is always mounted on a bike; no on-foot movement at any time.
- Bike health == player life; reaching 0 triggers a death sequence.
- On death: player and bike detach into two independent ragdoll objects.
- Wreckage persists for exactly `Config.Bike.RespawnSeconds`, then respawn.
- Respawn places the player at a `SpawnLocation`, already mounted.
- Respects the repo golden rule: code drives Studio-built geometry; it never
  fabricates geometry and fails loudly when required assets are absent.

## Scope

**In scope**

- Auto-spawn + bind on join and on every character load.
- Server-authoritative seat binding (cannot walk, cannot jump out).
- Death detection via `CombatService`, signalled to `BikeService`.
- Detach + dual ragdoll (player corpse + bike), 3s wreck linger.
- Cleanup + respawn at a `SpawnLocation` already mounted.
- Repurpose the existing InputController `R` bind as a debug self-destruct.

**Out of scope** (per `CLAUDE.md` → Current scope; do not pre-scaffold)

- Bike *driving* physics / movement. Alive bikes are anchored. Movement is a
  separate future feature.
- Scoring / kill credit (the existing `CombatService` source-award TODO stays).
- HUD respawn countdown or any UI beyond the existing placeholder.
- Teams / friendly-fire changes (`Config.Combat.FriendlyFire` untouched).
- Multiple bike types, customization, datastores.

## Studio asset contract (user-owned — golden rule)

The code locates these by fixed convention and fails loudly if absent. It will
never create geometry.

| Asset | Required form | Code locates by | Missing behavior |
|---|---|---|---|
| Bike template | `Model` named `Bike` at `ServerStorage/Assets/Bike`, containing a `VehicleSeat`, with `Model.PrimaryPart` set | `ServerStorage:FindFirstChild("Assets"):FindFirstChild("Bike")` | `warn` once, abort spawn |
| Spawn points | One or more `SpawnLocation` instances anywhere under `Workspace` | `Workspace:GetDescendants()` filtered to `SpawnLocation` | one-time `warn`, fall back to world origin `Vector3.new(0, SpawnHeight, 0)` |

Notes:

- The bike template lives in `ServerStorage` (server-only); a fresh clone is
  parented to `Workspace` per spawn.
- `Players.CharacterAutoLoads` stays at its default (`true`).
- Alive bike: `PrimaryPart` anchored; player held by the `VehicleSeat` weld.

## Components & responsibilities

### `shared/Config.luau`

- Reuse `Bike.RespawnSeconds` (currently `3`) as **both** the wreck linger
  duration and the respawn delay — they are the same window by design.
- Add one tuning value: `Bike.RagdollPushForce = 1500` (number, studs·mass
  impulse) — applied to the dead bike's `PrimaryPart` so it tumbles. Starting
  value; tune by feel. Added inside the existing frozen `Bike` table.
- No instance paths in Config; asset paths are documented constants in
  `BikeService`.

### `CombatService` (damage only — responsibility unchanged)

- Add a `Signal` field `BikeDied` created in `KnitInit`
  (`self.BikeDied = Signal.new()`), fired as `self.BikeDied:Fire(player, bike)`.
- At the existing death `TODO` site in `ApplyDamage` (the `if health <= 0`
  branch): keep setting the `Dead` attribute (harmless, useful for debugging
  and other readers) **and additionally** fire `BikeDied`. `CombatService`
  remains ignorant of who consumes the signal.
- The `player` argument is resolved from the bike's `OwnerUserId` attribute via
  `Players:GetPlayerByUserId`. If no owner resolves, fire with `nil` player and
  `BikeService` ignores it (non-player bike — not applicable yet but defensive).

### New dependency

- Add `Signal = "sleitnick/signal@^1.5.0"` to `[dependencies]` in `wally.toml`.
  Signal is already pulled transitively by Knit; declaring it directly makes
  `require(ReplicatedStorage.Packages.Signal)` resolve. Run `wally install`.

### `BikeService` (owns the lifecycle state machine)

- New per-player state map: `_state[player] ∈ {"Alive","Dying","Respawning"}`.
- New per-player respawn-timer handle so it can be cancelled.
- Rework `SpawnBike(player)`:
  1. Resolve a spawn position (random `SpawnLocation` + `Config.World.SpawnHeight`,
     or origin fallback).
  2. Clone the Studio bike template (abort + `warn` if missing).
  3. Set `Health` (= `Config.Bike.MaxHealth`) and `OwnerUserId` attributes;
     anchor `PrimaryPart`; parent to `Workspace`.
  4. Wait for `player.Character` (and its `Humanoid`) if needed.
  5. Bind: `VehicleSeat:Sit(humanoid)`; disable jump
     (`Humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)`);
     connect `Humanoid.Seated` so an unintended un-seat while `Alive` re-seats
     the player. This *is* "cannot walk."
  6. Track bike in `_bikes`; set `_state[player] = "Alive"`.
- Subscribe to `CombatService.BikeDied` in `KnitStart` (after Knit start so
  `CombatService` exists).
- Auto-spawn: on `Players.PlayerAdded` and each `player.CharacterAdded`,
  (re)bind via `SpawnBike`, so `LoadCharacter` can never leave the player
  walking.
- Extend the existing `PlayerRemoving` handler to cancel any pending respawn
  timer and clear `_state`.
- `Client:SpawnBike` is removed (binding is server-driven). `BikeController`
  drops `RequestSpawn` and the `_currentBike` request flow entirely — no
  speculative retention (per CLAUDE.md: do not pre-scaffold).

### Client

- `InputController`: replace the `R` "spawn" bind with a **debug
  self-destruct**. Add exactly one new client method
  `CombatService.Client:DebugKill(player)` that resolves the caller's bike via
  `BikeService:GetBike(player)` and calls `CombatService:ApplyDamage(bike,
  math.huge)`, driving the real death loop without ramming. Gated by a
  module-level `DEBUG_SELF_DESTRUCT = true` constant in `InputController`; the
  bind is not registered when false.
- `HudController`: unchanged (respawn countdown explicitly out of scope).

## Lifecycle state machine (per player)

```
                 join / CharacterAdded
                          │
                          ▼
   ┌──────────────────  Alive  ◄───────────────────┐
   │  (seated, bound, can't walk)                   │
   │                                                │
   │  CombatService.BikeDied (state == Alive)       │  SpawnBike on
   ▼                                                │  fresh character
 Dying ─ unseat (detach) ───────────────────────────┤
   │  ragdoll character (corpse)                    │
   │  ragdoll bike (unanchor + RagdollPushForce)    │
   │  start timer (Config.Bike.RespawnSeconds)      │
   │                                                │
   ▼  timer elapsed                                 │
 Respawning ─ destroy dead bike model ──────────────┘
            └ player:LoadCharacter() (disposes corpse)
              → CharacterAdded → SpawnBike → Alive
```

- Re-entrancy guard: `BikeDied` is ignored unless `_state[player] == "Alive"`,
  so damage during `Dying`/`Respawning` cannot double-trigger.

### Ragdoll mechanics

- **Character ("corpse"):** R15 only (default Roblox avatars); R6 is not
  supported in this iteration. On death: `Humanoid:ChangeState(
  Enum.HumanoidStateType.Physics)`, set `Humanoid.PlatformStand = true`,
  replace the character's `Motor6D` joints with `BallSocketConstraint`s so the
  body goes limp. No un-ragdoll routine is needed — after the wreck window,
  `player:LoadCharacter()` disposes the corpse and yields a fresh avatar.
- **Bike:** clear the seat occupant, unanchor all parts, set them
  `CanCollide = true`, and `PrimaryPart:ApplyImpulse(direction *
  Config.Bike.RagdollPushForce)` so it tumbles. After the wreck window the
  bike model is `:Destroy()`d.

## Data flow

`CombatService.ApplyDamage` (Health → 0) → `BikeDied:Fire(player, bike)` →
`BikeService` handler (state guard) → death sequence → timer →
`player:LoadCharacter()` → `CharacterAdded` → `SpawnBike` → `Alive`.

## Edge cases & error handling

- Damage during `Dying`/`Respawning`: ignored via state guard.
- Character not loaded at spawn time: wait on `player.CharacterAdded` /
  `player.Character`.
- Every new character re-applies the seat-bind (defends against `LoadCharacter`
  leaving the player able to walk).
- Bike template missing: `warn` (clear, names the expected path), abort spawn —
  this is the intended signal to build the asset in Studio.
- No `SpawnLocation`: one-time `warn`, spawn at world origin so the loop still
  works during arena prototyping.
- Player leaves mid-sequence: cancel pending respawn timer, clear `_state`,
  destroy their bike (extends existing `PlayerRemoving`).
- `BikeDied` with unresolved player (no `OwnerUserId` match): ignored.

## Files changed

| File | Change |
|---|---|
| `wally.toml` | Add `Signal = "sleitnick/signal@^1.5.0"` direct dependency |
| `src/shared/Config.luau` | Add `Bike.RagdollPushForce` to the frozen `Bike` table |
| `src/server/Services/CombatService.luau` | Add `BikeDied` signal (created in `KnitInit`); keep `Dead` attribute and fire `BikeDied` at the death site; add `Client:DebugKill` |
| `src/server/Services/BikeService.luau` | Template-clone spawn, seat-binding, state machine, death→ragdoll→respawn, auto-spawn on join/CharacterAdded, extended PlayerRemoving |
| `src/client/Controllers/BikeController.luau` | Drop `RequestSpawn`/request flow |
| `src/client/Controllers/InputController.luau` | Repurpose `R` → debug self-destruct |

No changes to `default.project.json`, `MotoJoust.rbxl` (user's domain),
`CLAUDE.md`, or tooling config.

## Verification

No automated tests (per `CLAUDE.md` — no test framework; do not add one).

**Headless:** `stylua src` → `selene src` → `rojo build default.project.json
-o build-check.rbxl` (then delete the throwaway). All must pass clean.

**Studio play-test checklist** (requires the Studio assets above):

1. Join → player is auto-mounted on a bike at a `SpawnLocation`.
2. Player cannot walk and cannot jump out of the seat.
3. Ram damage to 0 HP → player and bike detach into two separate ragdolls.
4. Wreckage (corpse + bike) remains visible ~3s, then disappears.
5. Player respawns at a `SpawnLocation`, already seated and bound.
6. Press `R` (debug) → triggers the full death loop without ramming.
7. Leave the game during the 3s window → no errors; bike cleaned up.
8. Remove all `SpawnLocation`s → one-time warn; player spawns at origin.
9. Remove the bike template → clear warn naming `ServerStorage/Assets/Bike`;
   spawn aborts without erroring elsewhere.

## Open questions

None — all resolved during brainstorming.
