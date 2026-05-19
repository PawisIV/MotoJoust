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
	local _, spawnYaw = primary.CFrame:ToOrientation()
	upright.CFrame = CFrame.Angles(0, spawnYaw, 0)
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
