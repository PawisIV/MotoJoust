--!strict
--[[
	HudController
	Owns the on-screen HUD (health, speed). Placeholder builds a minimal
	ScreenGui in code; replace with a real UI module/StarterGui asset later.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Packages.Knit)

local HudController = Knit.CreateController({
	Name = "HudController",
})

HudController._label = nil :: TextLabel?

function HudController:SetStatus(text: string)
	if self._label then
		self._label.Text = text
	end
end

function HudController:KnitStart()
	local player = Players.LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name = "MotoJoustHud"
	gui.ResetOnSpawn = false

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(0.3, 0.06)
	label.Position = UDim2.fromScale(0.02, 0.02)
	label.BackgroundTransparency = 0.4
	label.TextScaled = true
	label.Text = "MotoJoust — press R to spawn"
	label.Parent = gui

	self._label = label
	gui.Parent = player:WaitForChild("PlayerGui")
end

function HudController:KnitInit() end

return HudController
