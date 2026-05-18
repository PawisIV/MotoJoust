# Player-Bound Bike Death/Respawn Loop — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The player is permanently bound to a `VehicleSeat` bike; when bike `Health` hits 0 the player and bike detach into two ragdolls, linger 3s as wreckage, then the player respawns at a `SpawnLocation` already mounted on a fresh bike.

**Architecture:** Approach 1 (signal-driven). `CombatService` fires a `BikeDied` Signal at the death site; `BikeService` owns a per-player `Alive → Dying → Respawning` state machine that handles spawn, seat-binding, ragdoll, wreck timer, and respawn. No new services or modules (per the approved spec's Files-changed contract) — ragdoll/spawn logic lives as private functions inside `BikeService`.

**Tech Stack:** Roblox Luau, Rojo 7.7, Wally (Knit `^1.7.0`, adding Signal `^1.5.0`), StyLua, Selene. Branch: `feature/bike-spawn-on-death`. Spec: `docs/superpowers/specs/2026-05-18-bike-spawn-on-death-design.md`.

> **Testing note (read first):** This project has **no automated test framework**, and `CLAUDE.md` + the approved spec explicitly forbid adding one. Do **not** scaffold TestEZ/jest/etc. The verification gate for every code task is the project's real loop — `stylua src` → `selene src` → `rojo build` — plus the manual Studio play-test checklist in Task 6. "Expected output" in steps refers to that loop, not unit tests.

> **Shared verification block** (referred to below as **VERIFY**), run from repo root `C:\Users\User\Roblox\MotoJoust`:
> ```bash
> stylua src
> selene src
> rojo build default.project.json -o build-check.rbxl
> rm -f build-check.rbxl
> ```
> Expected: `stylua` prints nothing (exit 0); `selene` prints `0 errors`, `0 warnings`, `0 parse errors`; `rojo` prints `Built project to build-check.rbxl`. Any deviation = fix before commit.

---

### Task 1: Add the Signal Wally dependency

**Files:**
- Modify: `wally.toml`

- [ ] **Step 1: Add Signal to `[dependencies]`**

Replace the `[dependencies]` block in `wally.toml` so it reads exactly:

```toml
[dependencies]
Knit = "sleitnick/knit@^1.7.0"
Signal = "sleitnick/signal@^1.5.0"
```

(Leave `[package]`, the comment, and the empty `[dev-dependencies]` unchanged.)

- [ ] **Step 2: Install packages**

Run: `wally install`
Expected: ends with `Downloaded N packages!` and no error.

- [ ] **Step 3: Verify Signal resolves**

Run: `ls Packages`
Expected: output includes `Signal.lua` (alongside `Knit.lua`, `_Index`).

- [ ] **Step 4: Run VERIFY**

Run the **VERIFY** block. Expected as described above. (`Packages/` contents are git-ignored; the build does not resolve `require`s, so this passes even though no code uses Signal yet.)

- [ ] **Step 5: Commit**

```bash
git add wally.toml wally.lock
git commit -m "$(cat <<'EOF'
chore: add sleitnick/signal as direct Wally dependency

Needed so CombatService can require ReplicatedStorage.Packages.Signal
for the BikeDied signal. Already pulled transitively by Knit; this just
makes it directly requirable.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Add `RagdollPushForce` to Config

**Files:**
- Modify: `src/shared/Config.luau`

- [ ] **Step 1: Add the tuning value**

In `src/shared/Config.luau`, inside the `Bike = { ... }` table, add a `RagdollPushForce` line after `MaxHealth = 100,`. The `Bike` table must read exactly:

```lua
	Bike = {
		MaxSpeed = 90, -- studs/sec
		Acceleration = 45, -- studs/sec^2
		TurnSpeed = 2.4, -- rad/sec at full lean
		RespawnSeconds = 3,
		MaxHealth = 100,
		RagdollPushForce = 1500, -- impulse (scaled by mass) shoving a dead bike so it tumbles
	},
```

(The existing `table.freeze(Config.Bike)` at the bottom already covers the new key. `RespawnSeconds` is reused as both the wreck-linger and respawn delay — do not add a second value.)

- [ ] **Step 2: Run VERIFY**

Run the **VERIFY** block. Expected as described above.

- [ ] **Step 3: Commit**

```bash
git add src/shared/Config.luau
git commit -m "$(cat <<'EOF'
feat: add Bike.RagdollPushForce tuning value

Impulse applied to a dead bike so it tumbles on death. RespawnSeconds
is reused as both the wreck-linger and respawn delay.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: CombatService — `BikeDied` signal + `DebugKill`

**Files:**
- Modify: `src/server/Services/CombatService.luau` (full replacement)

- [ ] **Step 1: Replace the file contents**

Replace the entire contents of `src/server/Services/CombatService.luau` with exactly:

```lua
--!strict
--[[
	CombatService
	Owns damage resolution for the sandbox: ram collisions between bikes and
	any future weapons. All health changes go through ApplyDamage so balance
	and death handling stay in one place. On death it fires BikeDied; it does
	not know or care who handles respawn.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Signal = require(ReplicatedStorage.Packages.Signal)
local Config = require(ReplicatedStorage.Shared.Config)

local CombatService = Knit.CreateService({
	Name = "CombatService",
	Client = {},

	-- Signal.Signal<Player, Model>, created in KnitInit.
	BikeDied = nil :: any,
})

-- Applies `amount` damage to a bike model, clamping and handling death.
function CombatService:ApplyDamage(bike: Model, amount: number, _source: Model?)
	if amount <= 0 then
		return
	end

	local health = (bike:GetAttribute("Health") :: number?) or Config.Bike.MaxHealth
	health = math.max(0, health - amount)
	bike:SetAttribute("Health", health)

	if health <= 0 then
		bike:SetAttribute("Dead", true)
		local ownerUserId = bike:GetAttribute("OwnerUserId") :: number?
		local owner = if ownerUserId then Players:GetPlayerByUserId(ownerUserId) else nil
		if owner then
			self.BikeDied:Fire(owner, bike)
		end
	end
end

-- Converts a bike-vs-bike collision into ram damage based on closing speed.
function CombatService:ResolveRam(bikeA: Model, bikeB: Model, relativeSpeed: number)
	if relativeSpeed < Config.Combat.RamMinSpeed then
		return
	end

	local damage = (relativeSpeed - Config.Combat.RamMinSpeed) * Config.Combat.RamDamagePerStud
	damage = math.min(damage, Config.Combat.RamDamageCap)

	self:ApplyDamage(bikeB, damage, bikeA)
	self:ApplyDamage(bikeA, damage, bikeB)
end

-- Debug-only: lets a client instantly destroy their own bike to exercise the
-- death/respawn loop without ramming. Gated client-side by DEBUG_SELF_DESTRUCT.
function CombatService.Client:DebugKill(player: Player)
	local BikeService = Knit.GetService("BikeService")
	local bike = BikeService:GetBike(player)
	if bike then
		self.Server:ApplyDamage(bike, math.huge)
	end
end

function CombatService:KnitInit()
	self.BikeDied = Signal.new()
end

function CombatService:KnitStart() end

return CombatService
```

- [ ] **Step 2: Run VERIFY**

Run the **VERIFY** block. Expected as described above. (Behavioral correctness is checked in Studio in Task 6 — there is no headless way to run Knit.)

- [ ] **Step 3: Commit**

```bash
git add src/server/Services/CombatService.luau
git commit -m "$(cat <<'EOF'
feat: CombatService fires BikeDied signal + add DebugKill

Death site now keeps the Dead attribute AND fires BikeDied(player, bike),
resolving the owner from the bike's OwnerUserId. Adds a debug-only client
DebugKill to exercise the loop without ramming.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: BikeService — lifecycle state machine

**Files:**
- Modify: `src/server/Services/BikeService.luau` (full replacement)

This is the heart of the feature: template-clone spawn, seat-binding ("cannot walk"), the `Alive → Dying → Respawning` state machine, dual ragdoll, wreck timer, auto-spawn on join/respawn, and mid-sequence cleanup.

- [ ] **Step 1: Replace the file contents**

Replace the entire contents of `src/server/Services/BikeService.luau` with exactly:

```lua
--!strict
--[[
	BikeService
	Server authority for the player-bound bike lifecycle: spawn + seat-bind on
	join/respawn, death -> dual ragdoll -> wreck linger -> respawn at a
	SpawnLocation already mounted. The player is permanently bound to the bike's
	VehicleSeat and cannot walk. Damage math lives in CombatService; this
	service owns only lifecycle.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Config = require(ReplicatedStorage.Shared.Config)

-- Studio-built asset locations (golden rule: code drives, never fabricates).
local TEMPLATE_PARENT = "Assets" -- ServerStorage.Assets
local TEMPLATE_NAME = "Bike" -- ServerStorage.Assets.Bike (Model + VehicleSeat + PrimaryPart)

type State = "Alive" | "Dying" | "Respawning"

local BikeService = Knit.CreateService({
	Name = "BikeService",
	Client = {},

	_bikes = {} :: { [Player]: Model },
	_state = {} :: { [Player]: State },
	_respawnThreads = {} :: { [Player]: thread },
	_charConns = {} :: { [Player]: RBXScriptConnection },
})

local warnedNoSpawn = false
local warnedNoTemplate = false

-- Random SpawnLocation under Workspace, lifted by Config.World.SpawnHeight.
-- Falls back to world origin (with a one-time warn) if none exist.
local function getSpawnCFrame(): CFrame
	local spawns = {}
	for _, inst in workspace:GetDescendants() do
		if inst:IsA("SpawnLocation") then
			table.insert(spawns, inst)
		end
	end

	local lift = Vector3.new(0, Config.World.SpawnHeight, 0)
	if #spawns == 0 then
		if not warnedNoSpawn then
			warnedNoSpawn = true
			warn("[BikeService] No SpawnLocation under Workspace; spawning at origin. Add SpawnLocations in Studio.")
		end
		return CFrame.new(lift)
	end

	local chosen = spawns[math.random(1, #spawns)] :: SpawnLocation
	return CFrame.new(chosen.Position + lift)
end

-- Fresh clone of the Studio bike template, or nil (warns once if missing).
local function cloneTemplate(): Model?
	local parent = ServerStorage:FindFirstChild(TEMPLATE_PARENT)
	local template = parent and parent:FindFirstChild(TEMPLATE_NAME)
	if not template or not template:IsA("Model") then
		if not warnedNoTemplate then
			warnedNoTemplate = true
			warn(
				`[BikeService] Missing bike template at ServerStorage/{TEMPLATE_PARENT}/{TEMPLATE_NAME} `
					.. `(Model with a VehicleSeat and PrimaryPart set). Build it in Studio.`
			)
		end
		return nil
	end
	return template:Clone()
end

-- Collapses a character into a ragdoll "corpse" (R15 only; R6 unsupported).
local function ragdollCharacter(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid") :: Humanoid?
	if humanoid then
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
		humanoid.PlatformStand = true
	end

	for _, desc in character:GetDescendants() do
		if desc:IsA("Motor6D") then
			local part0, part1 = desc.Part0, desc.Part1
			if part0 and part1 then
				local a0 = Instance.new("Attachment")
				a0.CFrame = desc.C0
				a0.Parent = part0
				local a1 = Instance.new("Attachment")
				a1.CFrame = desc.C1
				a1.Parent = part1
				local socket = Instance.new("BallSocketConstraint")
				socket.Attachment0 = a0
				socket.Attachment1 = a1
				socket.Parent = part0
				desc:Destroy()
			end
		end
	end
end

-- Turns an alive (anchored) bike into free physics debris and shoves it.
local function ragdollBike(bike: Model)
	for _, part in bike:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.CanCollide = true
		end
	end
	local primary = bike.PrimaryPart
	if primary then
		local dir = Vector3.new(math.random() - 0.5, 1, math.random() - 0.5).Unit
		primary:ApplyImpulse(dir * Config.Bike.RagdollPushForce * primary.AssemblyMass)
	end
end

function BikeService:GetBike(player: Player): Model?
	return self._bikes[player]
end

function BikeService:DespawnBike(player: Player)
	local existing = self._bikes[player]
	if existing then
		existing:Destroy()
		self._bikes[player] = nil
	end
end

-- Spawns a bike for `character`, binds the player into its VehicleSeat so they
-- cannot walk, and marks them Alive.
function BikeService:SpawnBike(player: Player, character: Model)
	self:DespawnBike(player)

	local humanoid = character:FindFirstChildOfClass("Humanoid") :: Humanoid?
	if not humanoid then
		return
	end

	local bike = cloneTemplate()
	if not bike then
		return
	end

	bike.Name = string.format("Bike_%s", player.Name)
	bike:SetAttribute("OwnerUserId", player.UserId)
	bike:SetAttribute("Health", Config.Bike.MaxHealth)

	for _, part in bike:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
		end
	end

	bike.Parent = workspace
	bike:PivotTo(getSpawnCFrame())

	local seat = bike:FindFirstChildWhichIsA("VehicleSeat", true) :: VehicleSeat?
	if not seat then
		warn(`[BikeService] Bike template has no VehicleSeat; cannot bind {player.Name}.`)
		bike:Destroy()
		return
	end

	local seatAny = seat :: any
	seatAny:Sit(humanoid)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)

	-- Keep the player locked in while Alive: re-seat if they ever come loose.
	humanoid.Seated:Connect(function(active: boolean)
		if not active and self._state[player] == "Alive" then
			local current = self._bikes[player]
			local s = current and current:FindFirstChildWhichIsA("VehicleSeat", true)
			if s then
				local sAny = s :: any
				sAny:Sit(humanoid)
			end
		end
	end)

	self._bikes[player] = bike
	self._state[player] = "Alive"
end

function BikeService:_onBikeDied(player: Player, bike: Model)
	if self._state[player] ~= "Alive" then
		return
	end
	self._state[player] = "Dying"

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid") :: Humanoid?
	if humanoid then
		humanoid.Sit = false
	end
	if character then
		ragdollCharacter(character)
	end
	ragdollBike(bike)

	self._respawnThreads[player] = task.delay(Config.Bike.RespawnSeconds, function()
		self._respawnThreads[player] = nil
		self._state[player] = "Respawning"
		self:DespawnBike(player)
		if player.Parent then
			player:LoadCharacter()
		end
	end)
end

function BikeService:_onCharacterAdded(player: Player, character: Model)
	self:SpawnBike(player, character)
end

function BikeService:_onPlayerAdded(player: Player)
	self._state[player] = "Respawning"
	self._charConns[player] = player.CharacterAdded:Connect(function(character)
		self:_onCharacterAdded(player, character)
	end)
	if player.Character then
		self:_onCharacterAdded(player, player.Character)
	end
end

function BikeService:_onPlayerRemoving(player: Player)
	local thread = self._respawnThreads[player]
	if thread then
		task.cancel(thread)
		self._respawnThreads[player] = nil
	end
	local conn = self._charConns[player]
	if conn then
		conn:Disconnect()
		self._charConns[player] = nil
	end
	self:DespawnBike(player)
	self._state[player] = nil
end

function BikeService:KnitStart()
	local CombatService = Knit.GetService("CombatService")
	CombatService.BikeDied:Connect(function(player: Player, bike: Model)
		self:_onBikeDied(player, bike)
	end)

	Players.PlayerAdded:Connect(function(player)
		self:_onPlayerAdded(player)
	end)
	for _, player in Players:GetPlayers() do
		self:_onPlayerAdded(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		self:_onPlayerRemoving(player)
	end)
end

function BikeService:KnitInit() end

return BikeService
```

- [ ] **Step 2: Run VERIFY**

Run the **VERIFY** block. Expected as described above. If `selene` flags an unused variable, do not silence it with a config change — fix the code. If `stylua` reformats, that is expected (it edits in place); re-run `selene`/`rojo build` after.

- [ ] **Step 3: Commit**

```bash
git add src/server/Services/BikeService.luau
git commit -m "$(cat <<'EOF'
feat: BikeService player-bound lifecycle + death/respawn loop

Template-clone spawn at a SpawnLocation, seat-binding (no walking),
Alive/Dying/Respawning state machine, dual ragdoll on BikeDied, 3s
wreck linger, LoadCharacter respawn, mid-sequence cancellation, and
auto-spawn on join and every CharacterAdded.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Client — drop request flow, add debug self-destruct

**Files:**
- Modify: `src/client/Controllers/BikeController.luau` (full replacement)
- Modify: `src/client/Controllers/InputController.luau` (full replacement)

- [ ] **Step 1: Replace `BikeController.luau`**

Replace the entire contents of `src/client/Controllers/BikeController.luau` with exactly:

```lua
--!strict
--[[
	BikeController
	Bike spawning/binding is fully server-authoritative (BikeService). This
	controller is intentionally minimal — the public spawn-request flow was
	removed. Client-side bike behavior will be added when a feature needs it
	(do not pre-scaffold).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Packages.Knit)

local BikeController = Knit.CreateController({
	Name = "BikeController",
})

function BikeController:KnitInit() end

function BikeController:KnitStart() end

return BikeController
```

- [ ] **Step 2: Replace `InputController.luau`**

Replace the entire contents of `src/client/Controllers/InputController.luau` with exactly:

```lua
--!strict
--[[
	InputController
	Translates raw input into intent (throttle/steer) and exposes it via
	GetMoveVector so rebinding lives in one place. Also owns the debug
	self-destruct bind used to exercise the death/respawn loop.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Knit = require(ReplicatedStorage.Packages.Knit)

-- Set false to remove the debug "R = kill my bike" bind for playtests/release.
local DEBUG_SELF_DESTRUCT = true

local InputController = Knit.CreateController({
	Name = "InputController",
})

-- Returns throttle (-1..1) and steer (-1..1) from current keyboard state.
function InputController:GetMoveVector(): (number, number)
	local throttle = 0
	local steer = 0
	if UserInputService:IsKeyDown(Enum.KeyCode.W) then
		throttle += 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then
		throttle -= 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then
		steer += 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then
		steer -= 1
	end
	return throttle, steer
end

function InputController:KnitStart()
	if not DEBUG_SELF_DESTRUCT then
		return
	end
	local CombatService = Knit.GetService("CombatService")
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.R then
			CombatService:DebugKill()
		end
	end)
end

function InputController:KnitInit() end

return InputController
```

- [ ] **Step 3: Run VERIFY**

Run the **VERIFY** block. Expected as described above.

- [ ] **Step 4: Commit**

```bash
git add src/client/Controllers/BikeController.luau src/client/Controllers/InputController.luau
git commit -m "$(cat <<'EOF'
feat: server-authoritative binding; R = debug self-destruct

BikeController loses the spawn-request flow (binding is server-driven).
InputController's R now calls CombatService:DebugKill (gated by
DEBUG_SELF_DESTRUCT) to exercise the death/respawn loop without ramming.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Integration verification (headless + Studio play-test)

No code changes. This task confirms the feature works end to end. The headless gate is automatable; behavioral checks require Studio (the user runs these — Knit/physics cannot run headlessly).

- [ ] **Step 1: Full headless verify on the finished branch**

Run the **VERIFY** block once more. Expected: `stylua` clean, `selene` `0 errors / 0 warnings / 0 parse errors`, `rojo build` succeeds. Also run `git status --short` and confirm only intended files changed and `MotoJoust.rbxl` is untouched.

- [ ] **Step 2: Confirm Studio assets exist (user)**

In `MotoJoust.rbxl`, confirm:
- `ServerStorage/Assets/Bike` exists: a `Model` named `Bike`, containing a `VehicleSeat`, with `Model.PrimaryPart` set.
- At least one `SpawnLocation` exists somewhere under `Workspace`.

If either is missing, the code warns clearly and the loop will not function — build them, then continue.

- [ ] **Step 3: Studio play-test checklist (user)**

Open `MotoJoust.rbxl`, `rojo serve`, Connect, then Play and verify each:

1. Join → player is auto-mounted on a bike at a `SpawnLocation`.
2. WASD does not make the player walk off; player cannot jump out of the seat.
3. Drive/ram damage (or press `R`) until `Health` reaches 0 → player and bike detach into two separate ragdolls.
4. Wreckage (corpse + bike) stays visible ~3 seconds, then disappears.
5. Player respawns at a `SpawnLocation`, already seated and bound to a fresh bike.
6. Press `R` mid-life → triggers the full death loop without ramming.
7. Leave the game during the 3s wreck window → no errors in output; bike cleaned up.
8. Remove all `SpawnLocation`s and replay → one-time warn; player spawns at origin and the loop still works.
9. Remove `ServerStorage/Assets/Bike` and replay → clear warn naming the path; spawn aborts without cascading errors.

- [ ] **Step 4: Record the result**

If all checks pass, the feature is complete on `feature/bike-spawn-on-death`. If any check fails, capture the Studio Output text and treat it as a new defect (debug from the failing check; do not mark the plan complete). No commit in this task unless a fix was required (then commit the fix with a `fix:` message and the `Co-Authored-By` trailer).

---

## Self-Review (performed against the spec)

- **Spec coverage:** Studio asset contract → Task 4 (`cloneTemplate`/`getSpawnCFrame` + warns) & Task 6 Step 2. Config reuse + `RagdollPushForce` → Task 2. `CombatService` `BikeDied` + keep `Dead` + owner resolve + `DebugKill` → Task 3. New Signal dep → Task 1. `BikeService` state machine / bind / auto-spawn / dual ragdoll / wreck timer / respawn / `PlayerRemoving` cancel → Task 4. Client request-flow drop + gated debug `R` → Task 5. Headless + Studio verification → per-task VERIFY and Task 6. All spec sections map to a task.
- **Placeholder scan:** No TBD/TODO/“handle errors”/“similar to Task N”. Every code step shows the complete file.
- **Type/name consistency:** `SpawnBike(player, character)`, `GetBike`, `DespawnBike`, `_onBikeDied`, `_onCharacterAdded`, `_onPlayerAdded`, `_onPlayerRemoving`, `CombatService.BikeDied`, `CombatService.Client:DebugKill`, `Config.Bike.RagdollPushForce`/`RespawnSeconds`/`MaxHealth`, `Config.World.SpawnHeight` are used identically across Tasks 2–5. `DebugKill` (Task 3) is the exact method `InputController` calls (Task 5). `BikeService:GetBike` (Task 4) is what `DebugKill` calls (Task 3).
- **Scope:** Single cohesive feature, one branch, no new services/modules — matches the approved spec's Files-changed contract. No test framework added (per CLAUDE.md).
