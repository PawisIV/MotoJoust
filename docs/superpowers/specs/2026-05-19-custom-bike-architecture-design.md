# Design: Custom Arcade Bike Architecture (v1)

- **Date:** 2026-05-19
- **Status:** Approved (design); pending spec review
- **Topic:** custom-bike-architecture
- **Architecture decision:** Approach 1 — constraint-driven arcade movement on a
  simple unanchored bike, driver network-owned, reusing the existing
  player-bound death/respawn lifecycle.

## Summary

Replace the third-party A-Chassis "Souko's Bike Chassis" kit (removed for good)
with our own arcade-drivable bike. The player remains permanently bound to a
`VehicleSeat` bike; v1 adds **movement**: WASD throttle/steer, an always-upright
self-balance, and a "knockable" combat hook where a hard ram makes the victim's
bike **wobble** (rider stays seated — no eject). All of the merged
player-bound death → dual ragdoll → 3s wreck → respawn lifecycle is reused
unchanged; this feature is a movement layer + a ram/wobble hook, not a rewrite.

## Goals

- Player drives the bike with WASD (throttle/brake + steer), arcade feel.
- Bike self-balances upright while alive; cannot tip from driving/terrain.
- Bike-vs-bike ram deals damage (wires the existing `CombatService:ResolveRam`,
  which currently has no caller) and, above a speed threshold, a transient
  wobble on each victim that auto-recovers.
- No A-Chassis / no third-party kit anywhere in the project.
- Reuse the merged lifecycle (bind, Health/death, ragdoll, wreck, respawn) and
  the existing Knit/server-authoritative structure with no new state-machine
  states and no new services.

## Scope

**In scope (v1)**

- Arcade movement: forward/brake + steer via `InputController:GetMoveVector`.
- Always-upright self-balance via an `AlignOrientation`.
- Ram detection (bike-vs-bike contact) → `CombatService:ResolveRam`.
- Wobble-on-hard-ram (rider stays seated; no eject; no new states).
- A-Chassis removal + a new simple bike asset contract.

**Out of scope (per CLAUDE.md "current scope"; do not pre-scaffold)**

- Lean/tip physics, suspension, realistic handling.
- Rider eject / knockdown / a Knocked/Recovering state (explicitly rejected:
  "wobble-only").
- Movement anti-cheat / server-authoritative movement simulation.
- Weapons, scoring/kill credit, HUD beyond the existing placeholder, teams.
- Multiple bike types, customization, datastores.

## Networking & authority

The driver gets network ownership of the bike assembly automatically by
occupying the `VehicleSeat` (we already force-sit them), so movement is
client-simulated and responsive. The server stays authoritative for the
security-critical parts: Health, damage, death, and ram resolution
(`CombatService`). Wobble is decided server-side (from ram) and applied on the
owning client. This matches the approved arcade/sandbox decision; movement
anti-cheat is intentionally deferred.

## Studio asset contract (user-owned — golden rule)

The code locates the bike by the existing convention and fails loudly if
absent. It never fabricates geometry.

| Action | Detail |
|---|---|
| Delete A-Chassis | Remove `Workspace/Souko's Bike Chassis` **and** the A-Chassis copy at `ServerStorage/Assets/Bike`. No code references the kit by name — this is purely a `.rbxl` action. |
| New bike template | `Model` named `Bike` at `ServerStorage/Assets/Bike`. `Model.PrimaryPart` = a body `BasePart`. Contains a `VehicleSeat` positioned as the rider seat. All parts **unanchored** and welded to the body. Wheels optional (cosmetic only; arcade physics drives the body, not wheel colliders). |
| Spawn points | ≥1 `SpawnLocation` under `Workspace` (unchanged). |
| Persist | Build it, **Disconnect Rojo**, `Ctrl+S` (saves into `.rbxl`), reconnect, Play. |

Missing template → existing one-time `warn` + abort spawn. No `SpawnLocation` →
existing origin fallback + one-time `warn`.

## Components & responsibilities

### `src/shared/Config.luau`

Reuse `Bike.MaxSpeed`, `Bike.Acceleration`, `Bike.TurnSpeed`. Add to the frozen
tables:

- `Bike.UprightResponsiveness` (number) — `AlignOrientation.Responsiveness`
  while alive/stable.
- `Bike.WobbleResponsiveness` (number) — reduced responsiveness during a wobble
  (< `UprightResponsiveness`).
- `Bike.WobbleAngularImpulse` (number) — angular impulse magnitude applied to
  the bike on a hard ram.
- `Bike.WobbleRecoverSeconds` (number) — duration the wobble lasts before
  responsiveness is restored.
- `Combat.WobbleSpeed` (number) — closing-speed threshold above which a ram
  triggers wobble (independent of the existing `Combat.RamMinSpeed` damage
  threshold).
- `Combat.RamDebounceSeconds` (number) — per-ordered-pair cooldown so sustained
  contact does not spam `ResolveRam`.

### `src/server/Services/BikeService.luau` (deltas only)

- **Remove the anchor-all loop** in `SpawnBike` (the bike must be free to
  move). Defensively set body parts `Anchored = false` in case the template
  ships anchored.
- On spawn, create the movement rig on the bike (parented under the bike so it
  replicates to the owning client):
  - one velocity/force constraint for throttle along the bike's facing,
  - one angular-velocity constraint for steer,
  - one `AlignOrientation` for upright self-balance
    (`Responsiveness = Config.Bike.UprightResponsiveness`).
  Initial targets are zero (idle).
- Keep force-sit / jump-disable / reseat-guard / `_bikes` / `_state` /
  `PlayerRemoving` / death-respawn exactly as they are now.
- **Ram contact hook:** on spawn, connect the body's `.Touched`. On contact,
  resolve the other instance to a bike via the `OwnerUserId` attribute /
  `Bike_*` name, ignore self and non-bike hits, debounce per ordered pair for
  `Config.Combat.RamDebounceSeconds`, compute closing speed =
  `(bikeA.PrimaryPart.AssemblyLinearVelocity -
  bikeB.PrimaryPart.AssemblyLinearVelocity).Magnitude`, and call
  `CombatService:ResolveRam(bikeA, bikeB, closingSpeed)`.
- **Expose `BikeService:IsAlive(player): boolean`** (reads `_state`, returns
  `true` only when state is `Alive`) so `CombatService` can state-guard wobble
  without reaching into `BikeService` internals.
- **`ragdollBike` delta:** before unanchor/impulse, destroy the movement
  constraints and the `AlignOrientation` so the wreck tumbles freely (otherwise
  the upright constraint keeps a corpse-bike standing). Rest of the death path
  unchanged.

### `src/server/Services/CombatService.luau` (deltas only)

- `ResolveRam` keeps its existing damage math. Additionally: if
  `relativeSpeed > Config.Combat.WobbleSpeed`, fire a new client signal
  `Wobble` to each involved bike's owner (resolved via `OwnerUserId` →
  `Players:GetPlayerByUserId`). Guard: skip the `Wobble` fire unless
  `Knit.GetService("BikeService"):IsAlive(owner)` is true.
- Add the Knit client signal surface `Wobble` (server → specific client).
  `BikeDied`/`ApplyDamage`/`DebugKill` unchanged.

### `src/client/Controllers/BikeController.luau`

- Resolve the local player's bike (the one named `Bike_<LocalPlayer.Name>` /
  the seat the character occupies) and confirm the client owns it before
  driving.
- Each `RunService.Heartbeat`: read `InputController:GetMoveVector()` → set the
  throttle constraint's target (along bike facing, capped at
  `Config.Bike.MaxSpeed`, ramped by `Config.Bike.Acceleration`) and the steer
  constraint's target (`Config.Bike.TurnSpeed`). Zero targets when there is no
  owned/living bike.
- On the `Wobble` client signal: set `AlignOrientation.Responsiveness =
  Config.Bike.WobbleResponsiveness`, apply `Config.Bike.WobbleAngularImpulse`
  to the bike's `PrimaryPart`, and after `Config.Bike.WobbleRecoverSeconds`
  restore
  `Config.Bike.UprightResponsiveness`. Re-entrant wobbles refresh the timer.
- Stops cleanly when the bike despawns / player dies (driven by ownership +
  bike presence, not by tracking lifecycle state itself).

### `src/client/Controllers/InputController.luau`

Unchanged. `GetMoveVector` (WASD → throttle/steer) and the `R` debug
self-destruct already exist.

## Data flow

- **Spawn:** PlayerAdded/CharacterAdded → `BikeService:SpawnBike` (clone,
  unanchored, build movement rig + AlignOrientation, force-sit, connect
  `.Touched`) → seat occupancy → driver network ownership.
- **Drive:** client frame loop → `InputController:GetMoveVector` →
  `BikeController` sets constraint targets → client-simulated physics moves the
  owned bike (replicated).
- **Ram:** body `.Touched` (server, `BikeService`) → identify bike-vs-bike,
  debounce, closing speed → `CombatService:ResolveRam` → damage (Health; on 0
  → existing `BikeDied` → existing death lifecycle) and, if speed >
  `WobbleSpeed`, `Wobble` signal → owning client `BikeController` slackens
  AlignOrientation + angular impulse for `WobbleRecoverSeconds` → restore.
- **Death:** Health 0 → `BikeDied` → `BikeService` death sequence
  (`ragdollCharacter`; `ragdollBike` now also strips constraints + upright) →
  3s wreck → `LoadCharacter` → respawn. Unchanged otherwise.

## Edge cases & error handling

- Missing bike template → existing one-time warn + abort.
- No `SpawnLocation` → existing origin fallback + one-time warn.
- Client only drives a bike it owns and that exists (ownership + presence
  guard); zeroes targets otherwise.
- No wobble while owner is `Dying`/`Respawning` (state guard in CombatService
  before firing `Wobble`).
- `.Touched` per-pair debounce prevents `ResolveRam` spam from sustained
  contact.
- Player leaves mid-drive → existing `PlayerRemoving` cleanup destroys the bike
  (and its child constraints) and cancels timers.
- `ragdollBike` must remove constraints + AlignOrientation before the tumble,
  or the wreck stays unnaturally upright/driven.
- Template ships anchored → defensive `Anchored = false` on spawn.
- Re-entrant wobble (rapid repeated rams) → refresh the recover timer, do not
  stack impulses unboundedly.

## Files changed

| File | Change |
|---|---|
| `src/shared/Config.luau` | Add `Bike.UprightResponsiveness`, `Bike.WobbleResponsiveness`, `Bike.WobbleAngularImpulse`, `Bike.WobbleRecoverSeconds`, `Combat.WobbleSpeed`, `Combat.RamDebounceSeconds` |
| `src/server/Services/BikeService.luau` | Remove anchor-all; build movement rig + AlignOrientation on spawn; `.Touched` ram detector → `CombatService:ResolveRam`; `ragdollBike` strips constraints/upright; expose `IsAlive(player)` |
| `src/server/Services/CombatService.luau` | `ResolveRam` fires new `Wobble` client signal above `Combat.WobbleSpeed` (state-guarded); add `Wobble` client signal |
| `src/client/Controllers/BikeController.luau` | Movement loop on the owned bike from `GetMoveVector`; handle `Wobble` |

No changes to `InputController.luau`, the Knit bootstraps,
`default.project.json`, or `MotoJoust.rbxl` (user's domain). No new
files/services. No spec change to the merged 2026-05-18 design (this builds on
it; the seat-race fix `01cbf1b` is already in `master`).

## Verification

No automated tests (per CLAUDE.md — do not add a framework).

**Headless:** `stylua src` → `selene src` (0/0/0) → `rojo build
default.project.json -o build-check.rbxl` → delete it. All clean.

**Studio play-test checklist** (requires the new bike asset + a
`SpawnLocation`):

1. Spawn mounted; WASD drives forward/brake and steers; speed feels capped
   around `Config.Bike.MaxSpeed`.
2. Bike stays upright over bumps/slopes; does not tip from driving.
3. Two bikes ram: both take Health damage; above the wobble threshold both
   visibly wobble and auto-recover within `WobbleRecoverSeconds`; the rider
   never leaves the seat.
4. Sustained contact does not spam damage (debounce works).
5. Ram (or `R`) to 0 HP → existing dual ragdoll → ~3s wreck (wreck tumbles, is
   NOT held upright) → respawn at a `SpawnLocation` already mounted.
6. Cannot walk or jump out of the seat at any point.
7. No A-Chassis Tuner spam anywhere (kit fully removed).
8. Missing bike template / no `SpawnLocation` → the existing clear warnings.

## Open questions

None — all resolved during brainstorming (v1 = arcade-drivable; native
driver-owned physics; always-upright; knockable = wobble-only/no-eject; no new
states; ram detector lives in `BikeService`; new `Wobble` client signal).
