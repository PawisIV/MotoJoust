# Custom Arcade Bike Architecture (v1) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the player-bound bike arcade movement (WASD), an always-upright self-balance, and a ram→wobble combat hook — replacing the removed A-Chassis kit — while reusing the merged death/respawn lifecycle unchanged.

**Architecture:** Approach 1. The driver network-owns the bike via `VehicleSeat` occupancy and the owning client drives it through constraints created on spawn: a `LinearVelocity` (planar drive) and an `AlignOrientation` (upright + heading; steering = rotating its target yaw, so there is no AngularVelocity-vs-AlignOrientation conflict). The server stays authoritative for Health/damage/death and detects bike-vs-bike contact (`.Touched`) to drive the existing `CombatService:ResolveRam`, which additionally fires a `Wobble` client signal above a speed threshold.

**Tech Stack:** Roblox Luau, Rojo 7.7, Wally (Knit `^1.7.0`, Signal), StyLua, Selene. Branch base: `master` @ `4867e5b`. Spec: `docs/superpowers/specs/2026-05-19-custom-bike-architecture-design.md`.

> **Testing note (read first):** No automated test framework exists and `CLAUDE.md` + the spec forbid adding one. Do **not** scaffold tests. The gate for every code task is **VERIFY** below. Physics/constraint *feel* can only be confirmed in Studio (Task 6) — VERIFY proves it parses/builds, not that it feels right; all tunables live in `Config` so feel-tuning needs no code edits.

> **VERIFY block** (run from repo root `C:\Users\User\Roblox\MotoJoust`):
> ```bash
> stylua src
> selene src
> rojo build default.project.json -o build-check.rbxl
> rm -f build-check.rbxl
> ```
> Expected: `stylua` silent (exit 0); `selene` → `0 errors`, `0 warnings`, `0 parse errors`; `rojo` → `Built project to build-check.rbxl`.

> **Branch/commit:** base is `master` (default branch). Per harness rule, each task commits on a short branch then fast-forwards into `master` and deletes the branch (the pattern used all session). Never stage `MotoJoust.rbxl`. Every commit message ends with the `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>` trailer.

---

### Task 1: Config — movement/wobble tuning values

**Files:** Modify `src/shared/Config.luau`

- [ ] **Step 1: Add the tuning values**

Replace the `Bike = { ... }` and `Combat = { ... }` tables so the file's `Config` table reads exactly (rest of file unchanged — the `table.freeze` lines already cover new keys):

```lua
	Bike = {
		MaxSpeed = 90, -- studs/sec
		Acceleration = 45, -- studs/sec^2
		TurnSpeed = 2.4, -- rad/sec yaw at full steer
		RespawnSeconds = 3,
		MaxHealth = 100,
		RagdollPushForce = 1500, -- impulse (scaled by mass) shoving a dead bike so it tumbles
		UprightResponsiveness = 30, -- AlignOrientation.Responsiveness while stable
		WobbleResponsiveness = 5, -- weakened responsiveness during a wobble
		WobbleAngularImpulse = 9000, -- angular impulse applied to PrimaryPart on a hard ram
		WobbleRecoverSeconds = 1.2, -- how long a wobble lasts before upright is restored
	},

	Combat = {
		-- Ram damage scales with relative speed between two bikes.
		RamMinSpeed = 25, -- below this, a collision does no damage
		RamDamagePerStud = 0.8, -- damage = (relativeSpeed - RamMinSpeed) * this
		RamDamageCap = 60,
		FriendlyFire = false,
		WobbleSpeed = 60, -- closing speed above which a ram also triggers a wobble
		RamDebounceSeconds = 0.5, -- per-pair cooldown so sustained contact doesn't spam ResolveRam
	},
```

- [ ] **Step 2: Run VERIFY** — expected as described.

- [ ] **Step 3: Commit**

```bash
git checkout -b feat/bike-config && git add src/shared/Config.luau && git commit -m "$(cat <<'EOF'
feat: add bike movement + wobble tuning to Config

UprightResponsiveness/WobbleResponsiveness/WobbleAngularImpulse/
WobbleRecoverSeconds and Combat.WobbleSpeed/RamDebounceSeconds.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)" && git checkout master && git merge --ff-only feat/bike-config && git branch -d feat/bike-config
```

---

### Task 2: BikeService — drive rig, unanchor, ragdoll-strip, IsAlive

**Files:** Modify `src/server/Services/BikeService.luau` (full replacement)

Removes the anchor-all loop, builds the constraint rig on spawn, strips it on death, and exposes `IsAlive`. (The `.Touched` ram detector is Task 3 — kept separate for a smaller diff.)

- [ ] **Step 1: Replace the file contents**

Replace the entire contents of `src/server/Services/BikeService.luau` with exactly:

```lua
--!strict
--[[
	BikeService
	Server authority for the player-bound bike lifecycle: spawn + seat-bind on
	join/respawn, death -> dual ragdoll -> wreck linger -> respawn at a
	SpawnLocation already mounted. The player is permanently bound to the bike's
	VehicleSeat and cannot walk. On spawn the bike gets a drive rig (LinearVelocity
	+ AlignOrientation) that the owning client steers. Damage math lives in
	CombatService; this service owns only lifecycle + the ram contact hook.
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

-- Builds the client-driven movement rig on the bike's PrimaryPart:
-- a planar LinearVelocity (BikeDrive) and an AlignOrientation (BikeUpright).
-- The owning client sets their targets each frame (see BikeController).
local function buildDriveRig(bike: Model)
	local primary = bike.PrimaryPart
	if not primary then
		return
	end

	local rootAtt = Instance.new("Attachment")
	rootAtt.Name = "BikeRoot"
	rootAtt.Parent = primary

	local drive = Instance.new("LinearVelocity")
	drive.Name = "BikeDrive"
	drive.Attachment0 = rootAtt
	drive.RelativeTo = Enum.ActuatorRelativeTo.World
	drive.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	drive.MaxForce = 1e6
	drive.VectorVelocity = Vector3.zero
	drive.Parent = primary

	local upright = Instance.new("AlignOrientation")
	upright.Name = "BikeUpright"
	upright.Mode = Enum.OrientationAlignmentMode.OneAttachment
	upright.Attachment0 = rootAtt
	upright.Responsiveness = Config.Bike.UprightResponsiveness
	upright.MaxTorque = 1e6
	upright.MaxAngularVelocity = 1e6
	upright.CFrame = CFrame.new()
	upright.Parent = primary
end

-- Removes the drive rig so a dead bike tumbles freely instead of staying
-- upright/driven.
local function stripDriveRig(bike: Model)
	local primary = bike.PrimaryPart
	if not primary then
		return
	end
	for _, name in { "BikeDrive", "BikeUpright", "BikeRoot" } do
		local inst = primary:FindFirstChild(name)
		if inst then
			inst:Destroy()
		end
	end
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

-- Strips the drive rig then turns the bike into free physics debris.
local function ragdollBike(bike: Model)
	stripDriveRig(bike)
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

function BikeService:IsAlive(player: Player): boolean
	return self._state[player] == "Alive"
end

function BikeService:DespawnBike(player: Player)
	local existing = self._bikes[player]
	if existing then
		existing:Destroy()
		self._bikes[player] = nil
	end
end

-- Spawns a bike for `character`, binds the player into its VehicleSeat so they
-- cannot walk, builds the drive rig, and marks them Alive.
function BikeService:SpawnBike(player: Player, character: Model)
	self:DespawnBike(player)

	-- CharacterAdded can fire before the character is fully spawned. Wait for
	-- the Humanoid AND HumanoidRootPart to exist before binding.
	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	local rootPart = character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	if not humanoid or not rootPart then
		return
	end

	-- WaitForChild only proves Humanoid/RootPart exist under the model; the
	-- character can still be unparented when CharacterAdded fires. VehicleSeat
	-- :Sit silently rejects a humanoid whose character is not in the world, so
	-- wait until the character is actually a descendant of Workspace.
	local guard = 0
	while not character:IsDescendantOf(workspace) and guard < 300 do
		task.wait()
		guard += 1
	end
	if not character:IsDescendantOf(workspace) then
		return
	end

	local bike = cloneTemplate()
	if not bike then
		return
	end

	bike.Name = string.format("Bike_%s", player.Name)
	bike:SetAttribute("OwnerUserId", player.UserId)
	bike:SetAttribute("Health", Config.Bike.MaxHealth)

	-- Drivable: the bike must be free physics (defensively unanchor in case the
	-- template ships anchored).
	for _, part in bike:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.CanCollide = true
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

	buildDriveRig(bike)

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

- [ ] **Step 2: Run VERIFY** — expected as described. (Behavioral check is Task 6 in Studio.)

- [ ] **Step 3: Commit**

```bash
git checkout -b feat/bike-rig && git add src/server/Services/BikeService.luau && git commit -m "$(cat <<'EOF'
feat: bike drive rig, unanchored bikes, ragdoll-strip, IsAlive

SpawnBike no longer anchors the bike; builds a LinearVelocity +
AlignOrientation rig on PrimaryPart. ragdollBike strips the rig so
wrecks tumble. Adds BikeService:IsAlive for the wobble guard.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)" && git checkout master && git merge --ff-only feat/bike-rig && git branch -d feat/bike-rig
```

---

### Task 3: BikeService — bike-vs-bike ram contact detector

**Files:** Modify `src/server/Services/BikeService.luau`

Wires the existing-but-never-called `CombatService:ResolveRam` via `.Touched`.

- [ ] **Step 1: Add a module-level debounce table**

Immediately after the lines:

```lua
local warnedNoSpawn = false
local warnedNoTemplate = false
```

add:

```lua
-- Per-unordered-pair cooldown so sustained contact doesn't spam ResolveRam.
local ramDebounce: { [string]: number } = {}
```

- [ ] **Step 2: Add a resolver + the detector connection**

Immediately before `function BikeService:KnitStart()` add this method:

```lua
-- Resolves a touched part to the owning bike Model (a Model with an
-- OwnerUserId attribute named "Bike_*"), or nil.
local function resolveBike(part: BasePart): Model?
	local node: Instance? = part
	while node do
		if node:IsA("Model") and node:GetAttribute("OwnerUserId") ~= nil then
			return node
		end
		node = node.Parent
	end
	return nil
end

function BikeService:_connectRam(bike: Model)
	local primary = bike.PrimaryPart
	if not primary then
		return
	end
	primary.Touched:Connect(function(hit: BasePart)
		local other = resolveBike(hit)
		if not other or other == bike then
			return
		end

		local idA = bike:GetAttribute("OwnerUserId") :: number?
		local idB = other:GetAttribute("OwnerUserId") :: number?
		if not idA or not idB then
			return
		end
		local ownerA = Players:GetPlayerByUserId(idA)
		local ownerB = Players:GetPlayerByUserId(idB)
		if not ownerA or not ownerB then
			return
		end
		if not self:IsAlive(ownerA) or not self:IsAlive(ownerB) then
			return
		end

		local key = (idA < idB) and `{idA}-{idB}` or `{idB}-{idA}`
		local now = os.clock()
		local last = ramDebounce[key]
		if last and now - last < Config.Combat.RamDebounceSeconds then
			return
		end
		ramDebounce[key] = now

		local pa = bike.PrimaryPart
		local pb = other.PrimaryPart
		if not pa or not pb then
			return
		end
		local closing = (pa.AssemblyLinearVelocity - pb.AssemblyLinearVelocity).Magnitude
		self._combat:ResolveRam(bike, other, closing)
	end)
end
```

- [ ] **Step 3: Store the CombatService ref and call the detector on spawn**

In `BikeService` add the field to the `Knit.CreateService({ ... })` table — change:

```lua
	_charConns = {} :: { [Player]: RBXScriptConnection },
})
```

to:

```lua
	_charConns = {} :: { [Player]: RBXScriptConnection },
	_combat = nil :: any,
})
```

In `KnitStart`, change:

```lua
	local CombatService = Knit.GetService("CombatService")
	CombatService.BikeDied:Connect(function(player: Player, bike: Model)
```

to:

```lua
	local CombatService = Knit.GetService("CombatService")
	self._combat = CombatService
	CombatService.BikeDied:Connect(function(player: Player, bike: Model)
```

In `SpawnBike`, change:

```lua
	buildDriveRig(bike)

	self._bikes[player] = bike
```

to:

```lua
	buildDriveRig(bike)
	self:_connectRam(bike)

	self._bikes[player] = bike
```

- [ ] **Step 4: Run VERIFY** — expected as described.

- [ ] **Step 5: Commit**

```bash
git checkout -b feat/ram-detector && git add src/server/Services/BikeService.luau && git commit -m "$(cat <<'EOF'
feat: bike-vs-bike .Touched ram detector -> CombatService:ResolveRam

Resolves contacts to owning bikes via OwnerUserId, alive-guards both
owners, debounces per pair (Config.Combat.RamDebounceSeconds), and
calls the previously-unwired ResolveRam with closing speed.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)" && git checkout master && git merge --ff-only feat/ram-detector && git branch -d feat/ram-detector
```

---

### Task 4: CombatService — `Wobble` client signal + fire on hard ram

**Files:** Modify `src/server/Services/CombatService.luau`

- [ ] **Step 1: Add the client signal to the service table**

Change:

```lua
local CombatService = Knit.CreateService({
	Name = "CombatService",
	Client = {},

	-- Signal.Signal<Player, Model>, created in KnitInit.
	BikeDied = nil :: any,
})
```

to:

```lua
local CombatService = Knit.CreateService({
	Name = "CombatService",
	Client = {
		-- Server -> owning client: "your bike was hard-rammed, wobble now".
		Wobble = Knit.CreateSignal(),
	},

	-- Signal.Signal<Player, Model>, created in KnitInit.
	BikeDied = nil :: any,
})
```

- [ ] **Step 2: Fire the wobble in ResolveRam**

Change the whole `ResolveRam` function:

```lua
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
```

to:

```lua
-- Server-side: nudge a bike's owner to wobble if they are alive.
function CombatService:_tryWobble(bike: Model)
	local ownerUserId = bike:GetAttribute("OwnerUserId") :: number?
	local owner = if ownerUserId then Players:GetPlayerByUserId(ownerUserId) else nil
	if not owner then
		return
	end
	local BikeService = Knit.GetService("BikeService")
	if BikeService:IsAlive(owner) then
		self.Client.Wobble:Fire(owner)
	end
end

-- Converts a bike-vs-bike collision into ram damage based on closing speed,
-- and a wobble on both riders above Config.Combat.WobbleSpeed.
function CombatService:ResolveRam(bikeA: Model, bikeB: Model, relativeSpeed: number)
	if relativeSpeed < Config.Combat.RamMinSpeed then
		return
	end

	local damage = (relativeSpeed - Config.Combat.RamMinSpeed) * Config.Combat.RamDamagePerStud
	damage = math.min(damage, Config.Combat.RamDamageCap)

	self:ApplyDamage(bikeB, damage, bikeA)
	self:ApplyDamage(bikeA, damage, bikeB)

	if relativeSpeed > Config.Combat.WobbleSpeed then
		self:_tryWobble(bikeA)
		self:_tryWobble(bikeB)
	end
end
```

- [ ] **Step 3: Run VERIFY** — expected as described.

- [ ] **Step 4: Commit**

```bash
git checkout -b feat/wobble-signal && git add src/server/Services/CombatService.luau && git commit -m "$(cat <<'EOF'
feat: CombatService Wobble client signal on hard ram

Adds Client.Wobble (Knit signal). ResolveRam fires it to each alive
owner when closing speed exceeds Config.Combat.WobbleSpeed.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)" && git checkout master && git merge --ff-only feat/wobble-signal && git branch -d feat/wobble-signal
```

---

### Task 5: BikeController — drive loop + wobble handler

**Files:** Modify `src/client/Controllers/BikeController.luau` (full replacement)

- [ ] **Step 1: Replace the file contents**

Replace the entire contents of `src/client/Controllers/BikeController.luau` with exactly:

```lua
--!strict
--[[
	BikeController
	Drives the local player's bike (server-spawned, named Bike_<Name>) via the
	rig BikeService built: sets BikeDrive (LinearVelocity) and BikeUpright
	(AlignOrientation) every Heartbeat from InputController:GetMoveVector.
	Steering rotates the upright target heading (no AngularVelocity, so the
	upright constraint never fights steering). Handles the Wobble signal.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Knit = require(ReplicatedStorage.Packages.Knit)
local Config = require(ReplicatedStorage.Shared.Config)

local BikeController = Knit.CreateController({
	Name = "BikeController",
})

BikeController._bike = nil :: Model?
BikeController._heading = 0 -- radians, world yaw
BikeController._speed = 0 -- current forward speed (studs/sec)
BikeController._wobbleUntil = 0 -- os.clock() time the wobble ends (0 = none)

function BikeController:_acquire(): Model?
	local player = Players.LocalPlayer
	local bike = workspace:FindFirstChild(`Bike_{player.Name}`)
	if not bike or not bike:IsA("Model") then
		self._bike = nil
		return nil
	end
	if bike ~= self._bike then
		-- New bike (join/respawn): seed heading from its current facing.
		self._bike = bike
		self._speed = 0
		self._wobbleUntil = 0
		local primary = bike.PrimaryPart
		if primary then
			local _, y = primary.CFrame:ToOrientation()
			self._heading = y
		end
	end
	return bike
end

function BikeController:_step(dt: number)
	local bike = self:_acquire()
	if not bike then
		return
	end
	local primary = bike.PrimaryPart
	local drive = primary and primary:FindFirstChild("BikeDrive") :: LinearVelocity?
	local upright = primary and primary:FindFirstChild("BikeUpright") :: AlignOrientation?
	if not primary or not drive or not upright then
		return
	end

	local InputController = Knit.GetController("InputController")
	local throttle, steer = InputController:GetMoveVector()

	self._heading += steer * Config.Bike.TurnSpeed * dt

	local target = throttle * Config.Bike.MaxSpeed
	local step = Config.Bike.Acceleration * dt
	if self._speed < target then
		self._speed = math.min(self._speed + step, target)
	elseif self._speed > target then
		self._speed = math.max(self._speed - step, target)
	end

	local facing = CFrame.Angles(0, self._heading, 0)
	local fwd = facing.LookVector
	drive.VectorVelocity = Vector3.new(fwd.X * self._speed, primary.AssemblyLinearVelocity.Y, fwd.Z * self._speed)
	upright.CFrame = facing

	if self._wobbleUntil ~= 0 and os.clock() >= self._wobbleUntil then
		self._wobbleUntil = 0
		upright.Responsiveness = Config.Bike.UprightResponsiveness
	end
end

function BikeController:_onWobble()
	local bike = self._bike
	local primary = bike and bike.PrimaryPart
	local upright = primary and primary:FindFirstChild("BikeUpright") :: AlignOrientation?
	if not primary or not upright then
		return
	end
	upright.Responsiveness = Config.Bike.WobbleResponsiveness
	self._wobbleUntil = os.clock() + Config.Bike.WobbleRecoverSeconds
	local axis = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5)
	if axis.Magnitude > 0 then
		primary:ApplyAngularImpulse(axis.Unit * Config.Bike.WobbleAngularImpulse)
	end
end

function BikeController:KnitStart()
	local CombatService = Knit.GetService("CombatService")
	CombatService.Wobble:Connect(function()
		self:_onWobble()
	end)
	RunService.Heartbeat:Connect(function(dt: number)
		self:_step(dt)
	end)
end

function BikeController:KnitInit() end

return BikeController
```

- [ ] **Step 2: Run VERIFY** — expected as described.

- [ ] **Step 3: Commit**

```bash
git checkout -b feat/bike-controller && git add src/client/Controllers/BikeController.luau && git commit -m "$(cat <<'EOF'
feat: client bike drive loop + wobble handler

BikeController drives the owned bike's rig from GetMoveVector each
Heartbeat (steering = upright target heading), and weakens the upright
+ applies an angular impulse on the Wobble signal.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)" && git checkout master && git merge --ff-only feat/bike-controller && git branch -d feat/bike-controller
```

---

### Task 6: Integration verification + Studio play-test + handoff

No code. Confirms the feature end to end (headless is automatable; behavior is Studio-only — the user runs it).

- [ ] **Step 1: Final headless gate**

Run **VERIFY** on `master` HEAD. Run `git status --short` — confirm only intended files committed and `MotoJoust.rbxl` still unstaged. Run `git log --oneline -6` — confirm Tasks 1–5 commits present.

- [ ] **Step 2: Studio asset prep (user)**

In `MotoJoust.rbxl`: delete `Workspace/Souko's Bike Chassis` and any A-Chassis copy; build a simple unanchored `Model` named `Bike` at `ServerStorage/Assets/Bike` — a body `BasePart` set as `Model.PrimaryPart`, a `VehicleSeat` welded on top, optional cosmetic wheels (no kit/scripts). Keep ≥1 `SpawnLocation` under `Workspace`. Disconnect Rojo → `Ctrl+S` → reconnect → Play.

- [ ] **Step 3: Studio play-test checklist (user)**

1. Spawn mounted; **W** drives forward, **S** brake/reverse, **A/D** steer; speed feels capped near `Config.Bike.MaxSpeed`.
2. Bike stays upright over bumps/slopes; doesn't tip from driving.
3. Two bikes ram: both take Health damage; above the wobble threshold both visibly wobble and self-recover within ~`WobbleRecoverSeconds`; rider never leaves the seat.
4. Sustained scraping doesn't spam damage (debounce).
5. Ram (or `R`) to 0 HP → dual ragdoll → ~3s wreck that **tumbles freely** (not held upright) → respawn at a `SpawnLocation` already mounted.
6. Cannot walk or jump out of the seat at any time.
7. No A-Chassis Tuner spam anywhere.
8. Missing bike template / no `SpawnLocation` → the existing clear warnings.

If a check fails: capture Studio Output, treat as a defect (debug from the failing check; do not mark complete). Tuning-only issues (too fast/slow, weak/strong wobble, tippy) are **not** code defects — adjust `Config` values, no code change.

- [ ] **Step 4: Handoff**

Feature complete on `master` once headless is green and the user confirms the checklist. Then use `superpowers:finishing-a-development-branch` (note: already on `master`, no feature branch to merge — it will mostly confirm state / offer push). Do not push unless the user asks.

---

## Self-Review (performed against the spec)

- **Spec coverage:** A-Chassis removal + simple-bike contract → Task 6 Step 2 (user/golden-rule) + verified by checklist #7/#8. Config additions (incl. `RamDebounceSeconds`) → Task 1. Remove anchor-all + drive rig + `AlignOrientation` upright + `ragdollBike` strips rig + `IsAlive` → Task 2. `.Touched` ram detector → `ResolveRam` (debounced, alive-guarded, OwnerUserId) → Task 3. `Wobble` client signal + state-guarded fire above `WobbleSpeed` → Task 4. Client drive from `GetMoveVector` + wobble handling → Task 5. Networking (driver-owned via seat occupancy; server owns Health/death/ram) → unchanged + Tasks 2/3. Headless + Studio verification → per-task VERIFY + Task 6. Every spec section maps to a task.
- **Deviation from spec (justified, within deferred scope):** spec tentatively listed a separate angular-velocity steer constraint; plan folds steering into the `AlignOrientation` heading target instead — fewer instances, eliminates the AngularVelocity-vs-AlignOrientation conflict, and the spec explicitly deferred exact constraint instances to the plan. Behavior (throttle along facing capped at `MaxSpeed`, steer at `TurnSpeed`, upright self-balance) is unchanged.
- **Placeholder scan:** No TBD/TODO/"similar to Task N"/"handle errors". Every code step shows complete content. Config values are concrete starting numbers (tuning is expected in Studio per the testing note, not a placeholder).
- **Type/name consistency:** Rig instance names `BikeRoot`/`BikeDrive`/`BikeUpright` are created in Task 2 and read identically in Tasks 3/5. `BikeService:IsAlive` defined Task 2, called in Task 3 (`self:IsAlive`) and Task 4 (`BikeService:IsAlive`). `self._combat` set in Task 3 KnitStart, used in `_connectRam`. `CombatService.Client.Wobble` (`Knit.CreateSignal()`) fired server-side `self.Client.Wobble:Fire(owner)` (Task 4), consumed client-side `CombatService.Wobble:Connect` (Task 5) — correct Knit RemoteSignal pattern. `Config.Bike.*` / `Config.Combat.*` keys match Task 1 exactly. `GetMoveVector` returns `(throttle, steer)` per the existing `InputController`.
- **Scope:** Single cohesive feature; no new files/services; reuses the merged lifecycle. No test framework added (CLAUDE.md).
