--!strict
-- ShieldController.client.luau
-- ONLY handles input, fires remotes to server
-- Combat hooks are marked for Phase 2

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

print("[ShieldController] Started")

-- ========================================
-- REFERENCES
-- ========================================
local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local ShieldActivate = Remotes:WaitForChild("ShieldActivate")
local ShieldDeactivate = Remotes:WaitForChild("ShieldDeactivate")

-- ========================================
-- STATE
-- ========================================
local isShielding = false

-- ========================================
-- INPUT
-- ========================================
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode ~= Enum.KeyCode.F then return end
	if isShielding then return end

	isShielding = true
	ShieldActivate:FireServer()
	print("[ShieldController] Shield activate fired")
end)

UserInputService.InputEnded:Connect(function(input, processed)
	if input.KeyCode ~= Enum.KeyCode.F then return end
	if not isShielding then return end

	isShielding = false
	ShieldDeactivate:FireServer()
	print("[ShieldController] Shield deactivate fired")
end)

-- ========================================
-- PHASE 2 COMBAT HOOKS
-- Read these from CombatController:
-- isShielding → player is holding shield
-- ========================================