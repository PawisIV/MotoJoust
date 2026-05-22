-- TrailController
-- StarterCharacterScripts/Character/TrailController

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

print("[TrailController] Started")

-- ✅ Get character this way instead of script.Parent
local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid")
local rootPart = character:WaitForChild("HumanoidRootPart")

print("[TrailController] Character found: " .. character.Name)

-- Fire server to spawn trail
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 5)
local SpawnTrail = Remotes:WaitForChild("SpawnTrail", 5)
SpawnTrail:FireServer()

print("[TrailController] Trail spawn requested")
-- ========================================
-- VFX LIST
-- Add any new VFX here only
-- No need to touch anything else
-- ========================================
local VFX_LIST = {

	-- Trail 1 — Main wide trail
	{
		type = "trail",
		template = ReplicatedStorage.VFX.Trails.DefaultTrail,
		attachment0Position = Vector3.new(-3, -2, 0),
		attachment1Position = Vector3.new(3, -2, 0),
		properties = {
			Lifetime = 1.0,
			MinLength = 0.01,
			MaxLength = 0,
			WidthScale = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 5),
				NumberSequenceKeypoint.new(1, 3),
			}),
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 100, 0)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 0, 0)),
			}),
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(0.5, 0.3),
				NumberSequenceKeypoint.new(1, 1),
			}),
		}
	},

	-- Trail 2 — Glow inner trail
	-- {
	--     type = "trail",
	--     template = ReplicatedStorage.VFX.Trails.GlowTrail,
	--     attachment0Position = Vector3.new(-1, -2, 0),
	--     attachment1Position = Vector3.new(1, -2, 0),
	--     properties = {
	--         Lifetime = 1.5,
	--         MinLength = 0.01,
	--     }
	-- },

	-- Particle — Spark emitter at ground
	-- {
	--     type = "particle",
	--     template = ReplicatedStorage.VFX.Particles.SparkParticle,
	--     attachPosition = Vector3.new(0, -2.5, 0),
	-- },

}

-- ========================================
-- SPAWN ALL VFX FROM LIST
-- ========================================
local activeVFX = {} -- Store all spawned VFX here

for _, vfxData in ipairs(VFX_LIST) do

	if vfxData.type == "trail" then
		-- Create attachments
		local att0 = Instance.new("Attachment")
		att0.Position = vfxData.attachment0Position
		att0.Parent = rootPart

		local att1 = Instance.new("Attachment")
		att1.Position = vfxData.attachment1Position
		att1.Parent = rootPart

		-- Clone trail
		local trail = vfxData.template:Clone()
		trail.Attachment0 = att0
		trail.Attachment1 = att1
		trail.Enabled = false

		-- Apply properties
		for property, value in pairs(vfxData.properties) do
			trail[property] = value
		end

		trail.Parent = rootPart
		table.insert(activeVFX, { object = trail, type = "trail" })

	elseif vfxData.type == "particle" then
		-- Create single attachment
		local att = Instance.new("Attachment")
		att.Position = vfxData.attachPosition
		att.Parent = rootPart

		-- Clone particle
		local particle = vfxData.template:Clone()
		particle.Parent = att
		particle.Enabled = false

		table.insert(activeVFX, { object = particle, type = "particle" })
	end
end

-- ========================================
-- ENABLE/DISABLE ALL VFX WHEN MOVING
-- ========================================
RunService.Heartbeat:Connect(function()
	local isMoving = humanoid.MoveDirection.Magnitude > 0

	for _, vfx in ipairs(activeVFX) do
		if vfx.type == "trail" then
			vfx.object.Enabled = isMoving
		elseif vfx.type == "particle" then
			vfx.object.Enabled = isMoving
		end
	end
end)

print("VFX attached to " .. character.Name)