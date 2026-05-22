-- Script in ServerScriptService
-- TrailManager.lua

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SpawnTrail = ReplicatedStorage.Remotes.SpawnTrail

SpawnTrail.OnServerEvent:Connect(function(player)
	local character = player.Character
	if not character then return end

	local rootPart = character:WaitForChild("HumanoidRootPart")

	-- Create attachments on server
	local att0 = Instance.new("Attachment")
	att0.Position = Vector3.new(-3, -2, 0)
	att0.Parent = rootPart

	local att1 = Instance.new("Attachment")
	att1.Position = Vector3.new(3, -2, 0)
	att1.Parent = rootPart

	-- Clone and attach trail
	local trail = ReplicatedStorage.VFX.Trails.DefaultTrail:Clone()
	trail.Attachment0 = att0
	trail.Attachment1 = att1
	trail.Enabled = true -- Always on, server side
	trail.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 5),
		NumberSequenceKeypoint.new(1, 3),
	})
	trail.Lifetime = 3
	trail.MinLength = 0.01
	trail.Parent = rootPart
end)