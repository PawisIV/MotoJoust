--!strict
--[[
	InputController
	Translates raw input into intent (throttle/steer) and exposes it via
	GetMoveVector so rebinding lives in one place. Also locks out jumping
	(player is permanently bike-bound) and owns the debug self-destruct bind.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
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
	-- Player is permanently bound to a bike. Disabling the Humanoid Jumping
	-- state alone does NOT stop a VehicleSeat ejecting on jump, so sink the
	-- jump input before the default controls/seat ever see it (no jump
	-- attempt, no eject, no reseat snap-back). Ungated by the debug flag.
	ContextActionService:BindAction("MotoJoustNoJump", function()
		return Enum.ContextActionResult.Sink
	end, false, Enum.PlayerActions.CharacterJump)

	-- The CAS sink alone does not reliably stop a VehicleSeat exiting on jump.
	-- The local client owns its character, so authoritatively hold Jump = false
	-- every frame: the seat never sees a jump, so it never ejects.
	local localPlayer = Players.LocalPlayer
	RunService.Heartbeat:Connect(function()
		local character = localPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid") :: Humanoid?
		if humanoid then
			humanoid.Jump = false
		end
	end)

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
